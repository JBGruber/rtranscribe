# End-to-end tests. These need a real GGUF model; see helper-rtranscribe.R for
# how to enable them.

test_that("a model loads and reports its identity", {
  path <- skip_without_model()
  m <- transcribe_load_model(path)

  expect_s3_class(m, "transcribe_model")
  expect_true(nzchar(m$arch))
  expect_true(nzchar(m$backend))
  expect_match(paste(cli::cli_fmt(print(m)), collapse = " "), "transcribe_model")

  info <- transcribe_model_info(m)
  expect_true(nzchar(info$arch))

  caps <- transcribe_capabilities(m)
  expect_type(caps$languages, "character")
  expect_true(caps$max_timestamp_kind %in% c("none", "segment", "word", "token"))
  expect_type(transcribe_supports(m, "diarization"), "logical")
})

test_that("transcription produces text and well-formed tables", {
  path <- skip_without_model()
  pcm <- sample_audio()

  m <- transcribe_load_model(path)
  s <- transcribe_session(m)
  res <- transcribe_run(s, pcm)

  expect_s3_class(res, "transcribe_result")
  expect_equal(res$status, 0L)
  expect_gt(nchar(res$text), 0)

  # jfk.wav is the "ask not what your country can do for you" clip.
  expect_match(tolower(res$text), "country", fixed = TRUE)

  expect_s3_class(res$segments, "tbl_df")
  expect_true(all(c("start", "end", "text", "speaker_id") %in% names(res$segments)))
  expect_s3_class(res$words, "tbl_df")
  expect_s3_class(res$tokens, "tbl_df")
  expect_s3_class(res$speakers, "tbl_df")

  if (nrow(res$segments) > 0) {
    expect_true(all(res$segments$end >= res$segments$start))
    expect_true(all(res$segments$start >= 0))
  }

  expect_true(res$timestamp_kind %in% c("none", "segment", "word", "token"))
  expect_type(res$timings$encode, "double")
  expect_false(res$aborted)
})

test_that("results print and coerce", {
  path <- skip_without_model()
  pcm <- sample_audio()
  res <- transcribe(pcm, path)

  expect_match(paste(cli::cli_fmt(print(res)), collapse = " "), "transcribe_result")
  expect_equal(format(res), res$text)
  expect_equal(as.character(res), res$text)
  expect_s3_class(as.data.frame(res), "data.frame")
  expect_s3_class(as.data.frame(res, which = "segments"), "data.frame")
})

test_that("text is returned as valid UTF-8", {
  path <- skip_without_model()
  pcm <- sample_audio()
  res <- transcribe(pcm, path)

  expect_true(validUTF8(res$text))
  expect_true(Encoding(res$text) %in% c("UTF-8", "unknown"))
  if (nrow(res$segments) > 0) {
    expect_true(all(validUTF8(res$segments$text)))
  }
})

test_that("non-English audio keeps its glyphs", {
  path <- skip_without_model()
  wav <- system.file("extdata", "german.wav", package = "rtranscribe")
  skip_if(wav == "", "german sample not installed")
  skip_if_not_installed("av")

  m <- transcribe_load_model(path)
  caps <- transcribe_capabilities(m)
  skip_if(!caps$supports_language_detect, "model is monolingual")

  res <- transcribe(transcribe_read_audio(wav), m, language = "de")
  expect_true(validUTF8(res$text))
  expect_gt(nchar(res$text), 0)
})

test_that("a session can be reused across runs", {
  path <- skip_without_model()
  pcm <- sample_audio()

  m <- transcribe_load_model(path)
  s <- transcribe_session(m)

  first <- transcribe_run(s, pcm)
  second <- transcribe_run(s, pcm)
  expect_equal(first$text, second$text)
})

test_that("timestamps finer than the model supports are rejected", {
  path <- skip_without_model()
  pcm <- sample_audio()

  m <- transcribe_load_model(path)
  caps <- transcribe_capabilities(m)
  skip_if(caps$max_timestamp_kind == "token", "model supports the finest granularity")

  s <- transcribe_session(m)
  expect_error(transcribe_run(s, pcm, timestamps = "token"))
})

test_that("batch runs return one result per input", {
  path <- skip_without_model()
  pcm <- sample_audio()

  m <- transcribe_load_model(path)
  s <- transcribe_session(m)
  half <- pcm[seq_len(length(pcm) %/% 2)]

  res <- transcribe_run_batch(s, list(pcm, half), progress = FALSE)
  expect_length(res, 2)
  expect_s3_class(res[[1]], "transcribe_result")
  expect_gt(nchar(res[[1]]$text), 0)
})

test_that("session limits are readable", {
  path <- skip_without_model()
  m <- transcribe_load_model(path)
  s <- transcribe_session(m, n_threads = 2)

  lim <- transcribe_session_limits(s)
  expect_type(lim$effective_n_ctx, "integer")
  expect_true(is.numeric(lim$effective_max_audio))
  expect_match(paste(cli::cli_fmt(print(s)), collapse = " "), "transcribe_session")
})

test_that("tokenization returns ids or reports it is unsupported", {
  path <- skip_without_model()
  m <- transcribe_load_model(path)

  out <- tryCatch(transcribe_tokenize(m, "hello world"), error = function(e) e)
  if (inherits(out, "error")) {
    expect_match(conditionMessage(out), "not available")
  } else {
    expect_type(out, "integer")
    expect_gt(length(out), 0)
  }
})

test_that("streaming works when the model supports it", {
  path <- skip_without_model()
  pcm <- sample_audio()

  m <- transcribe_load_model(path)
  caps <- transcribe_capabilities(m)
  skip_if(!caps$supports_streaming, "model does not support streaming")

  s <- transcribe_session(m)
  res <- transcribe_stream_all(s, pcm, chunk_seconds = 1, progress = FALSE)

  expect_s3_class(res, "transcribe_result")
  expect_gt(nchar(res$text), 0)
})

test_that("streaming is refused for non-streaming models", {
  path <- skip_without_model()
  m <- transcribe_load_model(path)
  caps <- transcribe_capabilities(m)
  skip_if(caps$supports_streaming, "model supports streaming")

  s <- transcribe_session(m)
  expect_error(transcribe_stream_begin(s), "does not support streaming")
})

test_that("diarization populates speaker rows when supported", {
  path <- skip_without_model()
  pcm <- sample_audio()

  m <- transcribe_load_model(path)
  skip_if(!transcribe_supports(m, "diarization"), "model has no diarization")

  s <- transcribe_session(m)
  res <- transcribe_run(s, pcm, diarize = TRUE)
  expect_s3_class(res$speakers, "tbl_df")
  expect_true(all(c("start", "end", "speaker_id", "p") %in% names(res$speakers)))
})

test_that("whisper options are accepted by whisper models", {
  path <- skip_without_model()
  m <- transcribe_load_model(path)
  opts <- whisper_options(initial_prompt = "Ask not.")

  accepted <- transcribe_accepts_options(m, opts)
  skip_if(!isTRUE(accepted), "not a whisper model")

  s <- transcribe_session(m)
  res <- transcribe_run(s, sample_audio(), family = opts)
  expect_gt(nchar(res$text), 0)
  expect_s3_class(whisper_chunk_traces(s), "tbl_df")
})
