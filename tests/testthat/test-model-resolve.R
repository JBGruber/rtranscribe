# Resolving the `model` / `path` argument. A bare model name is downloaded on
# demand; anything path-shaped must stay a plain "file not found". The download
# itself is stubbed so these run offline.

# Stands in for transcribe_download_model(), recording what it was handed and
# aborting before any network access.
mock_download <- function(name, dest = NULL, overwrite = FALSE, quiet = FALSE,
                          ask = FALSE) {
  rlang::abort(
    "stubbed download",
    class = "rtranscribe_download_called",
    name = name,
    ask = ask
  )
}

local_stub_download <- function(env = parent.frame()) {
  testthat::local_mocked_bindings(
    transcribe_download_model = mock_download,
    .package = "rtranscribe",
    .env = env
  )
}

test_that("an existing file is used as is", {
  tmp <- dummy_gguf()
  on.exit(unlink(tmp))
  local_stub_download()

  expect_equal(rtranscribe:::resolve_model_path(tmp), tmp)
})

test_that("a bare model name is handed to transcribe_download_model()", {
  local_stub_download()

  cnd <- expect_error(
    rtranscribe:::resolve_model_path("whisper-tiny"),
    class = "rtranscribe_download_called"
  )
  expect_equal(cnd$name, "whisper-tiny")
  # The user is asked before a multi-hundred-MB download starts.
  expect_true(cnd$ask)
})

test_that("path-shaped arguments are missing files, not model names", {
  local_stub_download()

  expect_error(rtranscribe:::resolve_model_path("models/nope.gguf"), "not found")
  expect_error(rtranscribe:::resolve_model_path("~/nope.gguf"), "not found")
  expect_error(rtranscribe:::resolve_model_path("nope.gguf"), "not found")
})

test_that("an unknown bare name reports the registry, not a missing file", {
  expect_error(
    rtranscribe:::resolve_model_path("whisper-enormous"),
    "Unknown model"
  )
})

test_that("the argument name is used in the type-check message", {
  expect_error(rtranscribe:::resolve_model_path(1L), "`path`")
  expect_error(rtranscribe:::resolve_model_path(c("a", "b")), "single file path")
  expect_error(
    rtranscribe:::resolve_model_path(NA_character_, arg = "model"),
    "`model`"
  )
})

test_that("transcribe_load_model() downloads a model given by name", {
  local_stub_download()

  cnd <- expect_error(
    transcribe_load_model("whisper-tiny"),
    class = "rtranscribe_download_called"
  )
  expect_equal(cnd$name, "whisper-tiny")
})

test_that("transcribe() downloads a model given by name", {
  local_stub_download()

  cnd <- expect_error(
    transcribe("no-such-audio.wav", "whisper-tiny"),
    class = "rtranscribe_download_called"
  )
  expect_equal(cnd$name, "whisper-tiny")
})

test_that("neither entry point downloads for a path-shaped model", {
  local_stub_download()

  expect_error(transcribe_load_model("models/nope.gguf"), "not found")
  expect_error(transcribe("no-such-audio.wav", "models/nope.gguf"), "not found")
})

test_that("a model object or session is passed through untouched", {
  local_stub_download()

  expect_error(
    rtranscribe:::as_session(structure(list(), class = "not_a_model")),
    "must be a path"
  )
  s <- structure(list(), class = "transcribe_session")
  expect_identical(rtranscribe:::as_session(s), s)
})

test_that("a cached model is not re-downloaded", {
  dest <- file.path(tempdir(), "rtranscribe-cache-test")
  dir.create(dest, showWarnings = FALSE)
  on.exit(unlink(dest, recursive = TRUE))

  entry <- rtranscribe:::model_entry("whisper-tiny")
  cached <- file.path(dest, entry$file)
  writeBin(as.raw(0), cached)

  expect_equal(
    transcribe_download_model("whisper-tiny", dest = dest, quiet = TRUE, ask = TRUE),
    cached
  )
})
