#' @keywords internal
"_PACKAGE"

## usethis namespace: start
#' @useDynLib rtranscribe, .registration = TRUE
#' @importFrom Rcpp sourceCpp
## usethis namespace: end
NULL

# Package-level state: whether the backends were registered successfully, and
# the verbosity level for the buffered native log.
the <- new.env(parent = emptyenv())
the$backends_ok <- FALSE
the$verbosity <- "warn"

.onLoad <- function(libname, pkgname) {
  # Install the buffered log sink first. transcribe.cpp documents
  # transcribe_log_set() as a call to make once at startup, before any model is
  # loaded or any worker thread exists, and package load is exactly that point.
  # Without it the library writes diagnostics straight to stderr, bypassing cli.
  transcribe_set_verbosity(the$verbosity)

  # Idempotent; for the static CPU build this simply readies the compiled-in
  # CPU backend. A failure here is not fatal at load time -- it is reported
  # when the user actually tries to load a model.
  status <- cpp_init_backends_default()
  the$backends_ok <- identical(status, 0L)
  invisible()
}

.onAttach <- function(libname, pkgname) {
  if (!the$backends_ok) {
    packageStartupMessage(
      "rtranscribe: no compute backend could be registered. ",
      "Model loading will fail. See transcribe_devices()."
    )
  }
  invisible()
}

# Status codes that the C API documents as leaving a readable partial result.
TRANSCRIBE_OK <- 0L
