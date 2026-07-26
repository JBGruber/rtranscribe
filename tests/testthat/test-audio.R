test_that("the bundled clip decodes to 16 kHz mono PCM", {
  skip_if_not_installed("av")
  wav <- system.file("extdata", "jfk.wav", package = "rtranscribe")
  skip_if(wav == "", "bundled sample not installed")

  pcm <- transcribe_read_audio(wav)
  expect_type(pcm, "double")
  expect_gt(length(pcm), 16000) # more than a second
  expect_lte(max(abs(pcm)), 1.0)
  # jfk.wav is ~11 seconds
  expect_gt(length(pcm) / 16000, 5)
  expect_lt(length(pcm) / 16000, 20)
})

test_that("downsampling does not spam av's bogus resampler message", {
  skip_if_not_installed("av")
  # Needs a file whose native rate is above 16 kHz, otherwise no resampling
  # happens and the message never fires. av ships a 44.1 kHz sample.
  mp3 <- system.file("samples/Synapsis-Wonderland.mp3", package = "av")
  skip_if(mp3 == "", "av sample not available")

  # The message is written with REprintf, so it can only be seen by capturing
  # the message stream -- expect_silent() would not notice it.
  out <- tempfile()
  con <- file(out, open = "wt")
  sink(con, type = "message")
  pcm <- tryCatch(transcribe_read_audio(mp3), finally = {
    sink(type = "message")
    close(con)
  })
  emitted <- paste(readLines(out, warn = FALSE), collapse = "")
  unlink(out)

  expect_false(grepl("Insufficient memory", emitted, fixed = TRUE))
  # and the audio itself is complete: 30 s source, within one frame of 30 s
  expect_equal(length(pcm) / 16000, 30, tolerance = 0.01)
})

test_that("genuine messages are not swallowed by the av noise filter", {
  seen <- character()
  withCallingHandlers(
    rtranscribe:::without_av_noise(message("a real diagnostic")),
    message = function(m) {
      seen <<- c(seen, conditionMessage(m))
      invokeRestart("muffleMessage")
    }
  )
  expect_true(any(grepl("a real diagnostic", seen)))
})

test_that("the message sink is restored even when decoding fails", {
  before <- sink.number(type = "message")
  try(rtranscribe:::without_av_noise(stop("boom")), silent = TRUE)
  expect_equal(sink.number(type = "message"), before)
})

test_that("duration is reported in seconds", {
  expect_equal(transcribe_audio_duration(numeric(16000)), 1)
  expect_equal(transcribe_audio_duration(numeric(8000)), 0.5)
})

test_that("missing audio files produce a clear error", {
  expect_error(transcribe_read_audio("no-such-file.wav"), "not found")
  expect_error(transcribe_read_audio(c("a.wav", "b.wav")), "single file path")
})

test_that("the cache directory is a single path", {
  d <- transcribe_cache_dir()
  expect_type(d, "character")
  expect_length(d, 1)
})

test_that("the model registry is a static tibble, not a function", {
  expect_s3_class(rtranscribe:::transcribe_registry, "tbl_df")
  expect_false(is.function(rtranscribe:::transcribe_registry))
  expect_true(all(
    c("name", "repo", "file", "family", "size_mb", "wer", "note") %in%
      names(rtranscribe:::transcribe_registry)
  ))
  # Every curated entry must be fully annotated; that is the point of curating.
  reg <- rtranscribe:::transcribe_registry
  expect_false(anyNA(reg$family))
  expect_false(anyNA(reg$note))
  expect_false(anyNA(reg$size_mb))
  expect_false(anyDuplicated(reg$name) > 0)
})

test_that("transcribe_models() returns the curated set by default", {
  m <- transcribe_models()
  expect_s3_class(m, "tbl_df")
  expect_gt(nrow(m), 0)
  expect_equal(nrow(m), nrow(rtranscribe:::transcribe_registry))
  expect_true(all(c("name", "family", "size_mb", "wer", "downloaded", "note") %in% names(m)))
  expect_type(m$downloaded, "logical")
})

test_that("unknown model names are rejected before any download", {
  expect_error(transcribe_download_model("not-a-model"), "Unknown model")
})

test_that("a failed refresh warns and falls back to the curated set", {
  local_mocked_bindings(
    hf_gguf_models = function(...) stop("no network")
  )
  expect_warning(m <- transcribe_models(refresh = TRUE), "Could not fetch")
  expect_equal(nrow(m), nrow(rtranscribe:::transcribe_registry))
})

test_that("refresh appends unannotated rows below the curated ones", {
  fake <- tibble::tibble(
    name = c("whisper-tiny", "brand-new-model"), # first one is already curated
    repo = c("handy-computer/whisper-tiny-gguf", "handy-computer/brand-new-model-gguf"),
    file = c("whisper-tiny-Q8_0.gguf", "brand-new-model-Q8_0.gguf"),
    family = NA_character_, size_mb = NA_real_, wer = NA_real_, note = NA_character_
  )
  local_mocked_bindings(hf_gguf_models = function(...) fake)

  curated <- transcribe_models()
  m <- transcribe_models(refresh = TRUE)

  # curated rows kept, in order, at the top
  expect_equal(m$name[seq_len(nrow(curated))], curated$name)
  # the duplicate was dropped, the genuinely new one appended at the bottom
  expect_equal(nrow(m), nrow(curated) + 1L)
  expect_equal(m$name[nrow(m)], "brand-new-model")
  expect_true(is.na(m$note[nrow(m)]))
  expect_true(is.na(m$family[nrow(m)]))
  expect_equal(anyDuplicated(m$name), 0L)

  # and the appended model becomes resolvable for download
  expect_equal(rtranscribe:::model_entry("brand-new-model")$repo,
               "handy-computer/brand-new-model-gguf")
})

test_that("refresh reaches the real catalogue", {
  skip_on_cran()
  skip_if_offline()
  skip_if_not_installed("httr2")

  m <- transcribe_models(refresh = TRUE)
  expect_gt(nrow(m), nrow(rtranscribe:::transcribe_registry))
  expect_equal(anyDuplicated(m$name), 0L)
  # Curated rows keep their annotations
  expect_false(is.na(m$note[m$name == "whisper-tiny"]))
})
