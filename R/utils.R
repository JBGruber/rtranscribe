# Internal helpers -----------------------------------------------------------

#' Coerce a named list of equal-length vectors to a tibble
#' @noRd
as_result_tbl <- function(x) {
  tibble::as_tibble(x)
}

#' Validate a scalar string against a set of allowed values
#' @noRd
match_opt <- function(value, choices, arg = deparse(substitute(value))) {
  if (is.null(value)) {
    return(NULL)
  }
  if (!is.character(value) || length(value) != 1L || is.na(value)) {
    cli::cli_abort("{.arg {arg}} must be a single string, not {.obj_type_friendly {value}}.")
  }
  if (!value %in% choices) {
    cli::cli_abort(c(
      "{.arg {arg}} must be one of {.or {.val {choices}}}.",
      "x" = "You supplied {.val {value}}."
    ))
  }
  value
}

#' Turn TRUE/FALSE/NULL into the C API's "default"/"off"/"on" tri-state
#' @noRd
as_tristate <- function(x, arg = deparse(substitute(x))) {
  if (is.null(x)) {
    return("default")
  }
  if (is.character(x)) {
    return(match_opt(x, c("default", "off", "on"), arg))
  }
  if (is.logical(x) && length(x) == 1L && !is.na(x)) {
    return(if (x) "on" else "off")
  }
  cli::cli_abort("{.arg {arg}} must be {.code TRUE}, {.code FALSE}, or one of {.val {c('default','off','on')}}.")
}

#' Check that a value is a single non-NA number
#' @noRd
check_scalar_int <- function(x, arg = deparse(substitute(x)), allow_null = TRUE) {
  if (is.null(x)) {
    if (allow_null) {
      return(NULL)
    }
    cli::cli_abort("{.arg {arg}} must not be {.code NULL}.")
  }
  if (length(x) != 1L || is.na(x) || !is.numeric(x)) {
    cli::cli_abort("{.arg {arg}} must be a single number, not {.obj_type_friendly {x}}.")
  }
  as.integer(x)
}

#' Validate a PCM audio vector
#' @noRd
check_pcm <- function(x, arg = "audio") {
  if (!is.numeric(x)) {
    cli::cli_abort("{.arg {arg}} must be a numeric vector of PCM samples, not {.obj_type_friendly {x}}.")
  }
  if (length(x) == 0L) {
    cli::cli_abort("{.arg {arg}} is empty; at least one audio sample is required.")
  }
  if (anyNA(x)) {
    cli::cli_abort("{.arg {arg}} contains missing values.")
  }
  rng <- range(x)
  if (rng[1] < -1.01 || rng[2] > 1.01) {
    cli::cli_warn(c(
      "{.arg {arg}} has values outside [-1, 1] (range {.val {round(rng, 2)}}).",
      "i" = "transcribe.cpp expects normalised float PCM; results may be poor."
    ))
  }
  as.numeric(x)
}

#' Drain any buffered native log messages and re-emit them from R
#' @noRd
flush_native_log <- function() {
  logs <- cpp_log_drain()
  msgs <- logs$message
  if (length(msgs) == 0L) {
    return(invisible())
  }
  lvls <- logs$level
  for (i in seq_along(msgs)) {
    msg <- trimws(msgs[[i]])
    if (!nzchar(msg)) next
    switch(as.character(lvls[[i]]),
      "3" = cli::cli_alert_danger("{msg}"),
      "2" = cli::cli_alert_warning("{msg}"),
      cli::cli_alert_info("{msg}")
    )
  }
  invisible()
}

#' Run an expression, then flush the native log regardless of outcome
#' @noRd
with_native_log <- function(expr) {
  on.exit(flush_native_log(), add = TRUE)
  force(expr)
}

#' Format seconds as h:mm:ss.mmm for printing
#' @noRd
format_ts <- function(seconds) {
  if (length(seconds) == 0L) {
    return(character(0))
  }
  neg <- seconds < 0
  s <- abs(seconds)
  h <- floor(s / 3600)
  m <- floor((s - h * 3600) / 60)
  sec <- s - h * 3600 - m * 60
  out <- sprintf("%02d:%02d:%06.3f", as.integer(h), as.integer(m), sec)
  out[neg] <- paste0("-", out[neg])
  out
}
