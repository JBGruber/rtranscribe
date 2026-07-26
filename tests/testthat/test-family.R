test_that("whisper options carry the right kind and slot", {
  o <- whisper_options(initial_prompt = "GESIS, Mannheim", temperature = 0.2)
  expect_s3_class(o, "transcribe_family_options")
  expect_equal(o$kind, "whisper_run")
  expect_equal(o$slot, "run")
  expect_equal(o$initial_prompt, "GESIS, Mannheim")
  expect_equal(o$temperature, 0.2)
})

test_that("unset whisper options are dropped rather than passed as NULL", {
  o <- whisper_options(temperature = 0)
  expect_false("initial_prompt" %in% names(o))
  expect_true("temperature" %in% names(o))
})

test_that("stream option helpers target the stream slot", {
  expect_equal(parakeet_stream_options()$slot, "stream")
  expect_equal(parakeet_stream_options(att_context_right = 13)$att_context_right, 13)
  expect_equal(parakeet_buffered_stream_options(left_ms = 100)$kind, "parakeet_buffered_stream")
  expect_equal(moonshine_streaming_options()$kind, "moonshine_streaming")
  expect_equal(voxtral_realtime_options(num_delay_tokens = 4)$num_delay_tokens, 4)
})

test_that("prompt_condition is validated", {
  expect_error(whisper_options(prompt_condition = "sometimes"), "must be one of")
  expect_equal(whisper_options(prompt_condition = "all_segments")$prompt_condition, "all_segments")
})

test_that("transcribe_accepts_options rejects non-helper input", {
  expect_error(transcribe_accepts_options(NULL, list(kind = "x")), "family option helper")
})

test_that("family options print without error", {
  # cli writes through its own connection, so capture rather than expect_output.
  out <- cli::cli_fmt(print(whisper_options(temperature = 0)))
  expect_match(paste(out, collapse = " "), "whisper_run")

  out <- cli::cli_fmt(print(parakeet_stream_options()))
  expect_match(paste(out, collapse = " "), "defaults")

  expect_invisible(print(whisper_options()))
})
