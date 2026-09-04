# An existing but invalid file, for exercising argument checks that must fire
# before the native loader is reached.
dummy_gguf <- function() {
  p <- tempfile(fileext = ".gguf")
  writeBin(as.raw(0), p)
  p
}

# Integration tests need a real model, which is far too large to ship. Point
# RTRANSCRIBE_TEST_MODEL at a .gguf to enable them:
#
#   Sys.setenv(RTRANSCRIBE_TEST_MODEL = "~/models/whisper-tiny-Q8_0.gguf")
#
# or let the suite download the smallest registered model by setting
# RTRANSCRIBE_TEST_DOWNLOAD=1.
test_model_path <- function() {
  p <- Sys.getenv("RTRANSCRIBE_TEST_MODEL", "")
  if (nzchar(p) && file.exists(path.expand(p))) {
    return(path.expand(p))
  }
  if (identical(Sys.getenv("RTRANSCRIBE_TEST_DOWNLOAD"), "1")) {
    return(transcribe_download_model("whisper-tiny", quiet = TRUE))
  }
  ""
}

skip_without_model <- function() {
  p <- test_model_path()
  testthat::skip_if(
    !nzchar(p),
    "no test model; set RTRANSCRIBE_TEST_MODEL or RTRANSCRIBE_TEST_DOWNLOAD=1"
  )
  p
}

# Most small models cannot stream, so the streaming tests take a second model.
# Point RTRANSCRIBE_TEST_STREAM_MODEL at e.g. moonshine-streaming-tiny.
stream_model_path <- function() {
  p <- Sys.getenv("RTRANSCRIBE_TEST_STREAM_MODEL", "")
  if (nzchar(p) && file.exists(path.expand(p))) {
    return(path.expand(p))
  }
  if (identical(Sys.getenv("RTRANSCRIBE_TEST_DOWNLOAD"), "1")) {
    return(transcribe_download_model("moonshine-streaming-tiny", quiet = TRUE))
  }
  ""
}

skip_without_stream_model <- function() {
  p <- stream_model_path()
  testthat::skip_if(
    !nzchar(p),
    "no streaming test model; set RTRANSCRIBE_TEST_STREAM_MODEL"
  )
  p
}

sample_audio <- function(name = "jfk.wav") {
  wav <- system.file("extdata", name, package = "rtranscribe")
  testthat::skip_if(wav == "", "bundled sample not installed")
  testthat::skip_if_not_installed("av")
  transcribe_read_audio(wav)
}

# The catalogue of known models is remembered both in the session environment
# and in the cache directory, so tests that touch it need a private copy of
# both -- otherwise they see (and write to) the user's real cache.
forget_registry <- function() {
  the <- rtranscribe:::the
  rm(
    list = intersect(c("registry", "refreshed"), ls(the)),
    envir = the
  )
}

local_model_cache <- function(env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  withr::local_envvar(c(RTRANSCRIBE_CACHE = dir), .local_envir = env)
  forget_registry()
  withr::defer(forget_registry(), envir = env)
  dir
}

# A stand-in for the Hugging Face listing: one model already curated, one that
# only the full catalogue knows about.
fake_catalogue <- function() {
  tibble::tibble(
    name = c("whisper-tiny", "brand-new-model"),
    repo = c("handy-computer/whisper-tiny-gguf", "handy-computer/brand-new-model-gguf"),
    file = c("whisper-tiny-Q8_0.gguf", "brand-new-model-Q8_0.gguf"),
    family = NA_character_,
    size_mb = NA_real_,
    wer = NA_real_,
    note = NA_character_
  )
}
