#' @include os.R
#' @include stdio-server.R
#' @include logger.R
#'
#' @title Interpreter
#'
#' @description
#' This class is an interpreter for node in executable documents that contain R code.
#' It implements the `compile`, `execute`, and other core methods of Executa's
#' [Executor](https://github.com/stencila/executa/blob/v1.6.0/src/base/Executor.ts)
#' interface.
#'
#' @details
#' Currently only handles a single session.
#'
#' See [Pyla](https://github.com/stencila/pyla) and [Basha](https://github.com/stencila/basha)
#' for examples of implementations of interpreters for other languages, in other languages.
Interpreter <- R6::R6Class( # nolint
  "Interpreter",
  private = list(
    # List of servers
    servers = NULL,
    # Logger instance for this class
    log = logger("rasta:interpreter")
  ),
  public = list(
    #' @field envir Environment for the session
    envir = NULL,

    #' @description Initialize an `Interpreter` instance
    #'
    #' @param servers List of servers for the interpreter
    initialize = function(servers = list(StdioServer$new())) {
      private$servers <- servers
      self$envir <- globalenv() # TODO: allow global or own env with new.env()
    },

    #' @description Get the manifest for the interpreter.
    #'
    #' The manifest describes the capabilities and addresses of
    #' an executor so that peers know how to delegate method calls
    #' to this interpreter.
    #'
    #' @param then A function to call with the result
    manifest = function(then) {
      # Note: Use `I` to avoid inadvertent unboxing to scalars
      # when converting to JSON
      code_params <- list(
        required = I("node"),
        properties = list(
          node = list(
            required = c("type", "programmingLanguage"),
            properties = list(
              type = list(
                enum = c("CodeChunk", "CodeExpression")
              ),
              programmingLanguage = list(
                enum = c("r", "R")
              )
            )
          )
        )
      )

      manifest <- list(
        addresses = sapply(private$servers, function(server) server$addresses()),
        capabilities = list(
          manifest = TRUE,
          execute = code_params
        )
      )
      if (!missing(then)) then(manifest)
      else return(manifest)
    },

    #' @description Execute a node.
    #'
    #' @param node The node to execute. Usually, a `CodeChunk`.
    #' @param job The job id.
    #' @param then A function to call with the result
    #' @param ... Currently other arguments e.g. `session` are ignored.
    #' @returns The executed node with properties such as `outputs` and `errors`
    #' potentially updated.
    execute = function(node, job, then, ...) {
      # Options that may affect how they are executed, or
      # their values are decoded.
      options <- list()

      # Check for options in the node's `meta`` property
      if (!is.null(node$meta)) {
        options$width <- node$meta[["fig.width"]]
        options$height <- node$meta[["fig.height"]]
      }

      # Check for options in comments
      code <- node$text
      lines <- string_split(code, "\n")
      for (line in lines) {
        match <- string_match(line, "^\\s*#'\\s+@(\\w+)\\s*(.+)")
        if (!is.null(match)) {
          name <- match[2]
          value <- match[3]
          options[name] <- value
        }
      }

      # This is noisy, so usually best to leave commented out, but useful in some situations.
      # private$log$debug(paste('Executing', code))

      # Execute the code with timing
      before <- proc.time()[3]
      evaluation <- tryCatch({
        evaluate::evaluate(
          code,
          # Environment to evaluate in
          envir = self$envir,
          # Custom output handler for the `run` and `call` methods
          # Returns the value itself instead of the default which is to `print()` it
          output_handler = evaluate::new_output_handler(
            # No `visible` argument so that only visible values
            # are handled
            value = function(value) value
          )
        )
      }, error = identity)
      duration <- proc.time()[3] - before

      # Collect errors and outputs
      outputs <- list()
      errors <- list()
      if (inherits(evaluation, "error")) {
        # An error was caught by the tryCatch
        errors <- c(errors, list(stencilaschema::CodeError(
          errorType = "InternalError",
          errorMessage = as.character(evaluation)
        )))
      } else {
        # Iterate over the evaluation object and grab any errors
        # or outputs
        for (line in evaluation) {
          if (!inherits(line, "source")) {
            if (inherits(line, "error")) {
              errors <- c(errors, list(stencilaschema::CodeError(
                errorType = "RuntimeError",
                errorMessage = as.character(line$message)
              )))
            }
            else if (inherits(line, "warning")) {
              # Currently we do not have a place to put warnings
              # or other messages on the code chunk. Therefore,
              # send them to the log to avoid them polluting outputs.
              private$log$warn(trimws(line$message, "right"))
            }
            else if (inherits(line, "message")) {
              # As above, but treat other messages as info
              private$log$info(trimws(line$message, "right"))
            }
            else outputs <- c(outputs, list(line))
          }
        }
      }

      # Update the properties of the node and return it
      if (length(outputs) > 0) {
        # Use tryCatch to catch errors and attach them to the chunk
        tryCatch(
          # Supress warnings (in future, these might get captured as well)
          suppressWarnings({
            if (node$type == "CodeChunk") {
              # CodeChunks can have multiple output nodes
              # Iterate over outputs and group recordedplot objects so that
              # multiple graphics commands for same plot do not result in multiple
              # outputs. Non-recordedplot outputs separate the base graphics plots.
              # Note: this does not need to be done for ggplots
              node$outputs <- list()
              previous <- NULL
              for (output in outputs) {
                if (!(inherits(output, "recordedplot") && inherits(previous, "recordedplot"))) {
                  node$outputs <- c(node$outputs, list(decode(output, options)))
                  previous <- output
                }
              }
            } else if (node$type == "CodeExpression") {
              # CodeExpressions must have a single output, use the last one
              last <- outputs[[length(outputs)]]
              node$output <- as_scalar(decode(last, options))
            }
          }),
          error = function(error) {
            errors <<- c(errors, list(stencilaschema::CodeError(
              errorType = "RuntimeError",
              errorMessage = as.character(error$message)
            )))
          }
        )
      }
      node$errors <- if (length(errors) > 0) errors else NULL
      node$duration <- as_scalar(duration)

      if (!missing(then)) then(node)
      else return(node)
    },

    #' @description Dispatch a call to one of the interpreter's
    #' methods
    #'
    #' @param method The name of the method
    #' @param params A list of parameter values (i.e. arguments)
    #' @param then A function to call with the result
    #' @param catch A function to call with any error
    dispatch = function(method, params, then, catch) {
      func <- self[[method]]
      if (is.null(func)) stop(paste("Unknown interpreter method:", method))
      if (missing(params) || is.null(params)) params <- list()
      # NOTE: With the current API, the syntax `then = then` below is important!
      # It ensures that the params are bound the correct way when making the function call
      result <- tryCatch(do.call(func, c(params, list(then = then))))
      if (inherits(result, "error")) {
        if (!missing(catch)) catch(result)
        else stop(result)
      }
    },

    #' @description Register this interpreter on this machine.
    #'
    #' Creates a manifest file for the interpreter so that
    #' it can be used as a peer by other executors.
    register = function() {
      write(
        jsonlite::toJSON(self$manifest(), auto_unbox = TRUE, force = TRUE, pretty = TRUE),
        file.path(home_dir("executors", ensure = TRUE), "rasta.json")
      )
    },

    #' @description Start serving the interpreter
    #'
    #' @param background Run the server in the background with this duration, in seconds,
    start = function(background = -1) {
      for (server in private$servers) server$start(self, background = background)
    },

    #' @description Stop serving the interpreter
    stop = function() {
      for (server in private$servers) server$stop()
    }
  )
)
