# Backends and devices --------------------------------------------------------

#' Library version
#'
#' @return A list with the bundled transcribe.cpp `version` and the git
#'   `commit` it was built from.
#'
#' @examples
#' transcribe_version()
#'
#' @export
transcribe_version <- function() {
  cpp_version()
}

#' Compute devices and backends
#'
#' `transcribe_devices()` lists the compute devices registered with the runtime.
#' `transcribe_backend_available()` probes whether a named backend can be used.
#'
#' The default source build of this package is CPU-only, so `transcribe_devices()`
#' normally reports a single CPU device. GPU backends require a build configured
#' for them.
#'
#' @param kind One of `"auto"`, `"cpu"`, `"cpu_accel"`, `"metal"`, `"vulkan"`
#'   or `"cuda"`.
#'
#' @return `transcribe_devices()` returns a tibble with one row per device.
#'   `transcribe_backend_available()` returns a single logical.
#'
#' @examples
#' transcribe_devices()
#' transcribe_backend_available("cpu")
#'
#' @export
transcribe_devices <- function() {
  devs <- cpp_devices()
  if (length(devs) == 0L) {
    return(as_result_tbl(list(
      name = character(0), description = character(0), kind = character(0),
      device_id = character(0), device_type = character(0),
      memory_total = numeric(0), memory_free = numeric(0)
    )))
  }
  as_result_tbl(list(
    name = vapply(devs, function(d) d$name, character(1)),
    description = vapply(devs, function(d) d$description, character(1)),
    kind = vapply(devs, function(d) d$kind, character(1)),
    device_id = vapply(devs, function(d) d$device_id, character(1)),
    device_type = vapply(devs, function(d) d$device_type, character(1)),
    memory_total = vapply(devs, function(d) d$memory_total, numeric(1)),
    memory_free = vapply(devs, function(d) d$memory_free, numeric(1))
  ))
}

#' @rdname transcribe_devices
#' @export
transcribe_backend_available <- function(kind) {
  kind <- match_opt(kind, c("auto", "cpu", "cpu_accel", "metal", "vulkan", "cuda"))
  cpp_backend_available(kind)
}

#' Control native log verbosity
#'
#' transcribe.cpp emits diagnostics from its own code and from ggml. Those
#' messages can arrive on worker threads, so they are buffered natively and
#' re-emitted from R after each call rather than printed directly.
#'
#' @param level One of `"none"`, `"error"`, `"warn"` (default), `"info"` or
#'   `"debug"`.
#'
#' @return The previous level, invisibly.
#'
#' @examples
#' old <- transcribe_set_verbosity("info")
#' transcribe_set_verbosity(old)
#'
#' @export
transcribe_set_verbosity <- function(level = c("warn", "none", "error", "info", "debug")) {
  level <- match.arg(level)
  old <- the$verbosity
  # Severity rank understood by the native sink: 0 = errors only, rising to
  # 3 = everything including debug.
  rank <- switch(level,
    none = -1L,
    error = 0L,
    warn = 1L,
    info = 2L,
    debug = 3L
  )
  cpp_log_set(!identical(level, "none"), rank)
  the$verbosity <- level
  invisible(old)
}
