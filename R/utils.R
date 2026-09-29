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
    cli::cli_abort(
      "{.arg {arg}} must be a single string, not {.obj_type_friendly {value}}."
    )
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
  cli::cli_abort(
    "{.arg {arg}} must be {.code TRUE}, {.code FALSE}, or one of {.val {c('default','off','on')}}."
  )
}

#' Check that a value is a single non-NA number
#' @noRd
check_scalar_int <- function(
  x,
  arg = deparse(substitute(x)),
  allow_null = TRUE
) {
  if (is.null(x)) {
    if (allow_null) {
      return(NULL)
    }
    cli::cli_abort("{.arg {arg}} must not be {.code NULL}.")
  }
  if (length(x) != 1L || is.na(x) || !is.numeric(x)) {
    cli::cli_abort(
      "{.arg {arg}} must be a single number, not {.obj_type_friendly {x}}."
    )
  }
  as.integer(x)
}

#' Validate a PCM audio vector
#' @noRd
check_pcm <- function(x, arg = "audio") {
  if (!is.numeric(x)) {
    cli::cli_abort(
      "{.arg {arg}} must be a numeric vector of PCM samples, not {.obj_type_friendly {x}}."
    )
  }
  if (length(x) == 0L) {
    cli::cli_abort(
      "{.arg {arg}} is empty; at least one audio sample is required."
    )
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
    if (!nzchar(msg)) {
      next
    }
    switch(
      as.character(lvls[[i]]),
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

#' Format a duration in seconds for a status line
#' @noRd
format_duration <- function(seconds) {
  if (length(seconds) != 1L || !is.finite(seconds)) {
    return("audio")
  }
  if (seconds < 60) {
    return(sprintf("%.1f sec", seconds))
  }
  if (seconds < 3600) {
    return(sprintf("%.1f min", seconds / 60))
  }
  sprintf("%.1f hr", seconds / 3600)
}

#' Format elapsed wall time for the run spinner: "45s", "12m 3s", "1h 5m"
#' @noRd
format_elapsed <- function(seconds) {
  s <- as.integer(floor(max(seconds, 0)))
  if (s < 60L) {
    return(sprintf("%ds", s))
  }
  if (s < 3600L) {
    return(sprintf("%dm %ds", s %/% 60L, s %% 60L))
  }
  sprintf("%dh %dm", s %/% 3600L, (s %% 3600L) %/% 60L)
}

#' Status shown on the run spinner until the first heartbeat arrives
#' @noRd
ticker_waiting <- "encoding, updates start with decoding"

#' The cli format string for the run spinner
#'
#' The label and duration are baked in rather than left as `{...}` fields: cli
#' evaluates a format string in `.envir`, which is the *caller's* frame, so a
#' reference to a local of the function that built the bar never resolves and
#' every redraw fails silently. The part after the bar is the bar's status,
#' which `run_ticker()` sets: `ticker_waiting` until the first heartbeat, the
#' elapsed time from then on.
#' @noRd
ticker_format <- function(label, audio_seconds) {
  paste0(
    "{cli::pb_spin} ",
    label,
    " ",
    format_duration(audio_seconds),
    " of audio | {cli::pb_status}"
  )
}

#' Build the heartbeat closure handed to a native run, or NULL
#'
#' transcribe.cpp has no progress callback, and nothing in its API reports how
#' far through the audio a run is (every result accessor is gated on a flag
#' the families only set at commit time). The abort callback is the one hook
#' that fires mid-run, so that is what drives this: a spinner with elapsed
#' time, deliberately not a bar with a percentage, because no percentage is
#' knowable. See the "Interrupts" section of AGENTS.md.
#'
#' The returned closure is called re-entrantly from C while the native run
#' owns the stack, so it must not raise -- an error there is indistinguishable
#' from a consumed interrupt and silently stops the heartbeat.
#'
#' The line is drawn here, before the native call, rather than on the first
#' tick: nothing polls until the model's first decode step, and families that
#' encode the whole input and prefill it as one graph (MOSS, for one) spend
#' many minutes there on long audio, which would otherwise show nothing at
#' all. Elapsed time is counted from here too, so it includes that stretch.
#' @noRd
run_ticker <- function(
  audio_seconds,
  label = "Transcribing",
  spinner = TRUE,
  verbose = FALSE,
  envir = parent.frame()
) {
  id <- NULL
  started <- Sys.time()
  if (isTRUE(spinner)) {
    id <- cli::cli_progress_bar(
      format = ticker_format(label, audio_seconds),
      status = ticker_waiting,
      .envir = envir
    )
    cli::cli_progress_update(id = id, force = TRUE, .envir = envir)
  }
  function() {
    tryCatch(
      {
        # Drained here rather than only after the run so that a verbose long
        # job reports as it goes; cli redraws the bar around each message.
        if (isTRUE(verbose)) {
          flush_native_log()
        }
        if (!is.null(id)) {
          elapsed <- as.numeric(difftime(Sys.time(), started, units = "secs"))
          cli::cli_progress_update(
            id = id,
            status = paste(format_elapsed(elapsed), "elapsed"),
            .envir = envir
          )
        }
      },
      error = function(e) NULL,
      interrupt = function(e) NULL
    )
    invisible(NULL)
  }
}

#' Seconds between heartbeat calls into R
#'
#' The native poll fires every decode step (10-50 ms on CPU), far more often
#' than a status line needs redrawing, so the C layer throttles to this.
#' @noRd
tick_interval <- function() {
  x <- getOption("rtranscribe.tick_interval", 0.1)
  if (!is.numeric(x) || length(x) != 1L || !is.finite(x) || x < 0) {
    0.1
  } else {
    as.numeric(x)
  }
}

#' Resolve the progress/verbose pair into a tick closure for the native call
#'
#' Returns `NULL` when neither wants a heartbeat, which the C layer reads as
#' "install the abort hook for Ctrl-C only".
#' @noRd
maybe_ticker <- function(
  progress,
  verbose,
  audio_seconds,
  label = "Transcribing",
  envir = parent.frame()
) {
  progress <- progress %||%
    (interactive() && !isTRUE(getOption("knitr.in.progress")))
  if (!isTRUE(progress) && !isTRUE(verbose)) {
    return(NULL)
  }
  run_ticker(
    audio_seconds,
    label = label,
    spinner = isTRUE(progress),
    verbose = isTRUE(verbose),
    envir = envir
  )
}
