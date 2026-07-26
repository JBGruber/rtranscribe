test_that("version reports the bundled library version", {
  v <- transcribe_version()
  expect_type(v, "list")
  expect_named(v, c("version", "commit"))
  expect_match(v$version, "^[0-9]+\\.[0-9]+\\.[0-9]+$")
})

test_that("a CPU device is always registered", {
  devs <- transcribe_devices()
  expect_s3_class(devs, "tbl_df")
  expect_gt(nrow(devs), 0)
  expect_true("cpu" %in% devs$kind)
  expect_true(transcribe_backend_available("cpu"))
  expect_true(transcribe_backend_available("auto"))
})

test_that("unknown backend names are rejected", {
  expect_error(transcribe_backend_available("quantum"), "must be one of")
})

test_that("status strings round-trip", {
  expect_type(rtranscribe:::cpp_status_string(0L), "character")
  expect_match(rtranscribe:::cpp_status_string(9999L), ".")
})

test_that("verbosity can be set and restored", {
  old <- transcribe_set_verbosity("info")
  expect_type(old, "character")
  on.exit(transcribe_set_verbosity(old))
  expect_silent(transcribe_set_verbosity("none"))
})
