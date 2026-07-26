# Result objects --------------------------------------------------------------

#' Transcription results
#'
#' The object returned by [transcribe()], [transcribe_run()] and each element
#' of [transcribe_run_batch()]. It is a list with the following elements:
#'
#' \describe{
#'   \item{`text`}{The clean transcript, as a single UTF-8 string.}
#'   \item{`raw_text`}{The model's decode before family post-processing, with
#'     any speaker markers, timestamp tokens and special tags still present.}
#'   \item{`language`}{The language the model detected, or `""` when a
#'     `language` hint was supplied or the model has no detection head.}
#'   \item{`timestamp_kind`}{The granularity actually returned: `"none"`,
#'     `"segment"`, `"word"` or `"token"`. This is authoritative -- do not infer
#'     granularity from row counts.}
#'   \item{`segments`}{A tibble with `start`, `end` (seconds), `text` and
#'     `speaker_id`.}
#'   \item{`words`}{A tibble with `start`, `end`, `text` and `segment`.}
#'   \item{`tokens`}{A tibble with `id`, `p` (confidence, may be `NA`),
#'     `start`, `end`, `text`, `segment` and `word`.}
#'   \item{`speakers`}{A tibble of "who spoke when" rows, populated when
#'     diarization ran.}
#'   \item{`timings`}{A list of stage timings in seconds.}
#'   \item{`status`,`status_message`}{The terminal status of the run. Non-zero
#'     with a readable transcript means the result is partial.}
#'   \item{`aborted`,`truncated`}{Whether the run was cancelled, or stopped at
#'     the model's generation cap before finishing.}
#' }
#'
#' @name transcribe_result
#' @seealso [transcribe()], [transcribe_run()]
NULL

#' @noRd
new_transcribe_result <- function(x, audio_seconds = NA_real_) {
  x$segments <- as_result_tbl(x$segments)
  x$words <- as_result_tbl(x$words)
  x$tokens <- as_result_tbl(x$tokens)
  x$speakers <- as_result_tbl(x$speakers)
  x$audio_seconds <- audio_seconds
  structure(x, class = "transcribe_result")
}

#' @export
print.transcribe_result <- function(x, n = 5, ...) {
  ok <- identical(x$status, 0L)
  if (!ok) {
    cli::cli_alert_warning("Partial result: {x$status_message}")
  }

  nseg <- nrow(x$segments)
  hdr <- "{.cls transcribe_result}"
  cli::cli_text(hdr)

  bullets <- character(0)
  if (nzchar(x$language)) bullets <- c(bullets, "*" = "language: {.val {x$language}}")
  bullets <- c(bullets, "*" = "timestamps: {.val {x$timestamp_kind}}")
  if (!is.na(x$audio_seconds)) {
    rtf <- x$timings$encode + x$timings$decode + x$timings$mel
    speed <- if (!is.na(rtf) && rtf > 0) sprintf(" (%.1fx real time)", x$audio_seconds / rtf) else ""
    bullets <- c(bullets, "*" = paste0("audio: {round(x$audio_seconds, 1)}s", speed))
  }
  bullets <- c(bullets, "*" = "{nseg} segment{?s}, {nrow(x$words)} word{?s}")
  if (nrow(x$speakers) > 0) {
    ns <- length(unique(stats::na.omit(x$speakers$speaker_id)))
    bullets <- c(bullets, "*" = "{ns} speaker{?s}")
  }
  cli::cli_bullets(bullets)

  if (nseg > 0) {
    cli::cli_rule()
    show <- utils::head(x$segments, n)
    for (i in seq_len(nrow(show))) {
      spk <- show$speaker_id[[i]]
      lbl <- if (!is.na(spk)) paste0(" S", spk) else ""
      cli::cat_line(
        cli::col_grey(sprintf("[%s -> %s]%s ", format_ts(show$start[[i]]), format_ts(show$end[[i]]), lbl)),
        trimws(show$text[[i]])
      )
    }
    if (nseg > n) {
      cli::cat_line(cli::col_grey(sprintf("... %d more segment%s", nseg - n, if (nseg - n > 1) "s" else "")))
    }
  } else if (nzchar(x$text)) {
    cli::cli_rule()
    cli::cat_line(x$text)
  }
  invisible(x)
}

#' @export
format.transcribe_result <- function(x, ...) {
  x$text
}

#' Convert a transcription result to a data frame
#'
#' Returns the finest-grained table the run produced: words when word or token
#' timestamps were returned, otherwise segments. Pass `which` to choose
#' explicitly.
#'
#' @param x A [transcribe_result].
#' @param row.names,optional Ignored, present for S3 compatibility.
#' @param which One of `"auto"` (default), `"segments"`, `"words"`, `"tokens"`
#'   or `"speakers"`.
#' @param ... Ignored.
#'
#' @return A data frame.
#'
#' @examplesIf FALSE
#' as.data.frame(res)
#' as.data.frame(res, which = "words")
#'
#' @export
as.data.frame.transcribe_result <- function(x, row.names = NULL, optional = FALSE,
                                            which = c("auto", "segments", "words", "tokens", "speakers"),
                                            ...) {
  which <- match.arg(which)
  if (which == "auto") {
    which <- if (nrow(x$words) > 0) "words" else "segments"
  }
  as.data.frame(x[[which]], stringsAsFactors = FALSE)
}

#' @export
as.character.transcribe_result <- function(x, ...) {
  x$text
}

#' Whisper decoding traces
#'
#' Per-chunk observability for Whisper models: the temperature tier the
#' fallback loop accepted, the metrics that drove acceptance, and whether the
#' no-speech gate fired. Empty for non-Whisper models.
#'
#' @param session A `transcribe_session` that has just completed a run.
#'
#' @return A tibble, one row per 30-second encoder window.
#'
#' @examplesIf FALSE
#' res <- transcribe_run(s, pcm)
#' whisper_chunk_traces(s)
#'
#' @export
whisper_chunk_traces <- function(session) {
  as_result_tbl(cpp_whisper_chunk_traces(session_ptr(session)))
}
