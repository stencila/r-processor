context("issue-1")

test_that("decode_image_object() does not throw error", {
  # Create a temporary device as a temp file just so we
  # don't pollute the local dir with Rplots* files
  png(tempfile())
  # Need to enable recording for print devices.
  dev.control("enable")
  plot(1:10)
  value <- recordPlot()
  dev.off()

  image_object <- decode_image_object(value)
  expect_true(inherits(image_object, "ImageObject"))
  expect_match(image_object$contentUrl, "^data:image")
})
