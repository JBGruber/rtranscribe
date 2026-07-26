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
