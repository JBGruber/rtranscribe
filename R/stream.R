# Streaming -------------------------------------------------------------------

#' Incremental (streaming) transcription
#'
#' Streaming is a mode on a session rather than a separate handle: begin a
#' stream, feed audio chunks as they arrive, then finalize. Requires a model
#' whose capabilities report `supports_streaming = TRUE`.
#'
#' Two views of the text are available from [transcribe_stream_text()]:
#' `committed` is append-only and never rewritten, which is what a UI should
#' render; `full` is the model's current raw hypothesis and may be revised
#' anywhere.
#'
#' @param session A `transcribe_session`.
#' @param stream A `transcribe_stream` from `transcribe_stream_begin()`.
#' @param audio A numeric vector of 16 kHz mono PCM samples.
#' @param commit_policy When the committed text is allowed to grow: `"auto"`
#'   (default), `"on_finalize"` or `"stable_prefix"`.
#' @param stable_prefix_agreement_n How many consecutive hypotheses must agree
#'   on a prefix before it is committed. `NULL` uses the library default (3).
#' @inheritParams transcribe_run
#'
#' @return `transcribe_stream_begin()` returns a `transcribe_stream`.
#'   `transcribe_stream_feed()` and `transcribe_stream_finalize()` return an
#'   update list (invisibly for `feed`). `transcribe_stream_text()` returns a
#'   list with `full`, `committed` and `tentative`.
#'
#' @examplesIf FALSE
#' s <- transcribe_session(m)
#' st <- transcribe_stream_begin(s, family = moonshine_streaming_options())
#' for (chunk in chunks) transcribe_stream_feed(st, chunk)
#' transcribe_stream_finalize(st)
#' transcribe_stream_text(st)$committed
#'
#' @name transcribe_stream
NULL

#' @rdname transcribe_stream
#' @export
transcribe_stream_begin <- function(session,
                                    task = "transcribe",
                                    language = NULL,
                                    timestamps = "auto",
                                    diarize = NULL,
                                    pnc = NULL,
                                    itn = NULL,
                                    keep_special_tags = FALSE,
                                    family = NULL,
                                    commit_policy = "auto",
                                    stable_prefix_agreement_n = NULL) {
  if (!inherits(session, "transcribe_session")) {
    cli::cli_abort("{.arg session} must be a {.cls transcribe_session}.")
  }
  if (!is.null(session$model)) {
    caps <- tryCatch(transcribe_capabilities(session$model), error = function(e) NULL)
    if (!is.null(caps) && !isTRUE(caps$supports_streaming)) {
      cli::cli_abort(c(
        "This model does not support streaming.",
        "i" = "Use {.fn transcribe_run} for offline transcription."
      ))
    }
  }

  # A run-slot extension pointed at a stream is rejected by the native layer
  # with a generic INVALID_ARG, so catch the mismatch here where the message
  # can name the right helper.
  if (!is.null(family) && inherits(family, "transcribe_family_options") &&
    !identical(family$slot, "stream")) {
    cli::cli_abort(c(
      "{.arg family} must be a streaming option set, but {.val {family$kind}} applies to a run.",
      "i" = "Use one of {.fn parakeet_stream_options}, {.fn parakeet_buffered_stream_options},
             {.fn moonshine_streaming_options} or {.fn voxtral_realtime_options}."
    ))
  }

  run_opts <- build_run_opts(
    task = task, language = language, timestamps = timestamps,
    pnc = pnc, itn = itn, diarize = diarize,
    keep_special_tags = keep_special_tags, family = family
  )
  # The family extension belongs on the stream slot, not the run slot.
  run_opts$family <- NULL

  stream_opts <- list(
    family = family,
    commit_policy = match_opt(commit_policy, c("auto", "on_finalize", "stable_prefix")),
    stable_prefix_agreement_n = check_scalar_int(stable_prefix_agreement_n) %||% 0L
  )

  with_native_log(cpp_stream_begin(session$ptr, run_opts, stream_opts))
  structure(list(session = session), class = "transcribe_stream")
}

#' @rdname transcribe_stream
#' @export
transcribe_stream_feed <- function(stream, audio) {
  if (!inherits(stream, "transcribe_stream")) {
    cli::cli_abort("{.arg stream} must be a {.cls transcribe_stream} from {.fn transcribe_stream_begin}.")
  }
  pcm <- as_pcm(audio)
  upd <- with_native_log(cpp_stream_feed(stream$session$ptr, pcm, TRUE))
  invisible(upd)
}

#' @rdname transcribe_stream
#' @export
transcribe_stream_finalize <- function(stream) {
  if (!inherits(stream, "transcribe_stream")) {
    cli::cli_abort("{.arg stream} must be a {.cls transcribe_stream}.")
  }
  upd <- with_native_log(cpp_stream_finalize(stream$session$ptr, TRUE))
  if (isTRUE(upd$truncated)) {
    cli::cli_warn("The stream hit the model's generation cap; the transcript is incomplete.")
  }
  invisible(upd)
}

#' @rdname transcribe_stream
#' @export
transcribe_stream_text <- function(stream) {
  cpp_stream_text(session_ptr(stream))
}

#' @rdname transcribe_stream
#' @export
transcribe_stream_state <- function(stream) {
  st <- cpp_stream_state(session_ptr(stream))
  st$last_status_message <- cpp_status_string(st$last_status)
  st
}

#' @rdname transcribe_stream
#' @export
transcribe_stream_reset <- function(stream) {
  cpp_stream_reset(session_ptr(stream))
  invisible(stream)
}

#' @rdname transcribe_stream
#' @export
transcribe_stream_result <- function(stream) {
  raw <- cpp_stream_snapshot(session_ptr(stream))
  new_transcribe_result(raw)
}

#' Stream a whole audio vector in chunks
#'
#' Convenience wrapper that drives the full streaming lifecycle over one audio
#' vector, which is mostly useful for testing a streaming model and for
#' simulating live input.
#'
#' @inheritParams transcribe_stream
#' @param chunk_seconds Length of each fed chunk, in seconds.
#' @param progress Whether to show a progress bar. Defaults to `TRUE` in
#'   interactive sessions.
#' @param on_update Optional function called after each chunk with the current
#'   committed text and the update list. Useful for live display.
#' @param ... Further arguments passed to `transcribe_stream_begin()`, such as
#'   `timestamps` or `commit_policy`.
#'
#' @return A [transcribe_result].
#'
#' @examplesIf FALSE
#' transcribe_stream_all(s, pcm, chunk_seconds = 1)
#'
#' @export
transcribe_stream_all <- function(session,
                                  audio,
                                  chunk_seconds = 1,
                                  family = NULL,
                                  language = NULL,
                                  progress = NULL,
                                  on_update = NULL,
                                  ...) {
  pcm <- as_pcm(audio)
  chunk <- max(1L, as.integer(chunk_seconds * 16000))
  starts <- seq(1L, length(pcm), by = chunk)
  progress <- progress %||% interactive()

  stream <- transcribe_stream_begin(session, family = family, language = language, ...)
  on.exit(
    {
      if (identical(transcribe_stream_state(stream)$state, "active")) {
        transcribe_stream_reset(stream)
      }
    },
    add = TRUE
  )

  if (isTRUE(progress)) {
    id <- cli::cli_progress_bar("Streaming", total = length(starts), .envir = environment())
  }
  for (i in seq_along(starts)) {
    from <- starts[[i]]
    to <- min(from + chunk - 1L, length(pcm))
    upd <- transcribe_stream_feed(stream, pcm[from:to])
    if (!is.null(on_update)) {
      on_update(transcribe_stream_text(stream)$committed, upd)
    }
    if (isTRUE(progress)) cli::cli_progress_update(id = id, .envir = environment())
  }
  if (isTRUE(progress)) cli::cli_progress_done(id = id)

  transcribe_stream_finalize(stream)
  transcribe_stream_result(stream)
}

#' @export
print.transcribe_stream <- function(x, ...) {
  st <- transcribe_stream_state(x)
  cli::cli_text("{.cls transcribe_stream} ({.val {st$state}}, revision {st$revision})")
  txt <- tryCatch(transcribe_stream_text(x), error = function(e) NULL)
  if (!is.null(txt) && !is.na(txt$committed) && nzchar(txt$committed)) {
    cli::cat_line(txt$committed, cli::col_grey(txt$tentative))
  }
  invisible(x)
}
