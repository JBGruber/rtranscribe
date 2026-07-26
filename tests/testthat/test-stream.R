# Streaming needs a model whose capabilities advertise it; see
# helper-rtranscribe.R for how to point the suite at one.

test_that("a stream commits text incrementally and finalizes", {
  path <- skip_without_stream_model()
  pcm <- sample_audio()

  m <- transcribe_load_model(path)
  expect_true(transcribe_capabilities(m)$supports_streaming)

  s <- transcribe_session(m)
  st <- transcribe_stream_begin(s)
  expect_s3_class(st, "transcribe_stream")
  expect_equal(transcribe_stream_state(st)$state, "active")

  chunk <- 16000L
  committed <- character(0)
  for (i in seq(1L, length(pcm), by = chunk)) {
    upd <- transcribe_stream_feed(st, pcm[i:min(i + chunk - 1L, length(pcm))])
    expect_type(upd$revision, "integer")
    expect_gt(upd$input_received, 0)
    committed <- c(committed, transcribe_stream_text(st)$committed)
  }

  transcribe_stream_finalize(st)
  expect_equal(transcribe_stream_state(st)$state, "finished")

  txt <- transcribe_stream_text(st)
  expect_gt(nchar(txt$committed), 0)
  expect_true(validUTF8(txt$committed))
  expect_match(tolower(txt$committed), "country", fixed = TRUE)

  # committed_text is append-only: every observation must be a prefix of the
  # final committed text.
  final <- txt$committed
  for (c_i in committed) {
    if (nzchar(c_i)) {
      expect_equal(substr(final, 1, nchar(c_i)), c_i)
    }
  }
})

test_that("stream results marshal like one-shot results", {
  path <- skip_without_stream_model()
  pcm <- sample_audio()

  m <- transcribe_load_model(path)
  s <- transcribe_session(m)
  res <- transcribe_stream_all(s, pcm, chunk_seconds = 1, progress = FALSE)

  expect_s3_class(res, "transcribe_result")
  expect_gt(nchar(res$text), 0)
  expect_s3_class(res$segments, "tbl_df")
})

test_that("a stream can be reset and restarted", {
  path <- skip_without_stream_model()
  pcm <- sample_audio()

  m <- transcribe_load_model(path)
  s <- transcribe_session(m)

  st <- transcribe_stream_begin(s)
  transcribe_stream_feed(st, pcm[1:16000])
  transcribe_stream_reset(st)
  expect_equal(transcribe_stream_state(st)$state, "idle")

  st2 <- transcribe_stream_begin(s)
  expect_equal(transcribe_stream_state(st2)$state, "active")
  transcribe_stream_finalize(st2)
})

test_that("a run-slot option set is refused for streaming", {
  path <- skip_without_stream_model()
  m <- transcribe_load_model(path)
  s <- transcribe_session(m)

  expect_error(
    transcribe_stream_begin(s, family = whisper_options(temperature = 0)),
    "streaming option set"
  )
})

test_that("family stream options are accepted by their own family", {
  path <- skip_without_stream_model()
  m <- transcribe_load_model(path)

  opts <- moonshine_streaming_options(min_decode_interval_ms = 100)
  skip_if(!isTRUE(transcribe_accepts_options(m, opts)), "not a moonshine model")

  # A run-slot extension must not be accepted on the stream slot.
  expect_false(transcribe_accepts_options(m, whisper_options(temperature = 0)))

  s <- transcribe_session(m)
  st <- transcribe_stream_begin(s, family = opts)
  transcribe_stream_feed(st, sample_audio()[1:16000])
  transcribe_stream_finalize(st)
  expect_gt(nchar(transcribe_stream_text(st)$committed), 0)
})
