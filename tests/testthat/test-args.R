# Offline tests for argument -> enum mapping. These need no model, so they run
# everywhere and cover the mapping layer that is easiest to get wrong.

test_that("run options map R arguments onto the C enums", {
  opts <- rtranscribe:::build_run_opts()
  expect_equal(opts$task, "transcribe")
  expect_equal(opts$timestamps, "auto")
  expect_equal(opts$pnc, "default")
  expect_equal(opts$itn, "default")
  expect_equal(opts$diarize, "default")
  expect_false(opts$keep_special_tags)
  expect_equal(opts$spec_k_drafts, -1L)
})

test_that("logical toggles become the tri-state strings", {
  expect_equal(rtranscribe:::build_run_opts(diarize = TRUE)$diarize, "on")
  expect_equal(rtranscribe:::build_run_opts(diarize = FALSE)$diarize, "off")
  expect_equal(rtranscribe:::build_run_opts(diarize = NULL)$diarize, "default")
  expect_equal(rtranscribe:::build_run_opts(pnc = "off")$pnc, "off")
})

test_that("invalid enum values are rejected with a helpful message", {
  expect_error(rtranscribe:::build_run_opts(task = "summarise"), "must be one of")
  expect_error(rtranscribe:::build_run_opts(timestamps = "millisecond"), "must be one of")
  expect_error(rtranscribe:::build_run_opts(pnc = "maybe"), "must be")
})

test_that("family options must come from a helper", {
  expect_error(
    rtranscribe:::build_run_opts(family = list(kind = "whisper_run")),
    "family option helpers"
  )
})

test_that("PCM validation catches bad input", {
  expect_error(rtranscribe:::check_pcm("not audio"), "numeric vector")
  expect_error(rtranscribe:::check_pcm(numeric(0)), "empty")
  expect_error(rtranscribe:::check_pcm(c(0.1, NA)), "missing values")
  expect_warning(rtranscribe:::check_pcm(c(0, 50)), "outside")
  expect_silent(rtranscribe:::check_pcm(c(-1, 0, 1)))
})

test_that("timestamps are formatted for printing", {
  expect_equal(rtranscribe:::format_ts(0), "00:00:00.000")
  expect_equal(rtranscribe:::format_ts(61.5), "00:01:01.500")
  expect_equal(rtranscribe:::format_ts(3661), "01:01:01.000")
})

test_that("scalar integer checks accept NULL only when allowed", {
  expect_null(rtranscribe:::check_scalar_int(NULL))
  expect_equal(rtranscribe:::check_scalar_int(4), 4L)
  expect_error(rtranscribe:::check_scalar_int(NULL, allow_null = FALSE), "must not be")
  expect_error(rtranscribe:::check_scalar_int(c(1, 2)), "single number")
})
