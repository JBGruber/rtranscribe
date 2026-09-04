# Audio input -----------------------------------------------------------------

# av's read_audio_bin() prints this once per decoded frame -- thousands of times
# for a long file -- whenever the requested sample_rate is below the file's
# native rate, which is always the case for us (16 kHz).
#
# It is a false positive. av's src/fft.c does:
#
#     n_samples = swr_convert(swr, &buf, max_frame_size,
#                             frame->extended_data, frame->nb_samples);
#     if (n_samples < frame->nb_samples)
#         REprintf("Insufficient memory to recode all samples");
#
# which compares the OUTPUT sample count against the INPUT count. Downsampling
# 44.1 kHz to 16 kHz produces ~0.36 output samples per input sample, so the
# condition holds for essentially every frame regardless of memory. The code
# then appends all returned samples and swr_convert buffers any genuine
# remainder internally for the next call, so nothing is lost: a 30 s 44.1 kHz
# file decodes to 479984 samples at 16 kHz (29.999 s), the 16-sample shortfall
# being the resampler's final flush.
#
# Reported upstream as https://github.com/ropensci/av/issues/27 (no response).
#
# It is emitted with REprintf, so it is neither an R warning nor an ffmpeg log
# line: neither suppressWarnings() nor av::av_log_level() has any effect on it.
# Only the message stream can be intercepted.
av_downsample_noise <- "Insufficient memory to recode all samples"

#' Run an av decode with the known-bogus resampler message filtered out
#'
#' Captures the message stream for the duration of the call, drops the one
#' known-benign line, and re-emits anything else, so genuine decoder
#' diagnostics still reach the user.
#' @noRd
without_av_noise <- function(expr) {
  # R tracks a single message destination rather than a stack, so an existing
  # sink (knitr, Quarto, a caller's capture) is replaced rather than nested.
  # Remember it and put it back afterwards; the surviving lines are then
  # re-emitted into it, so a caller capturing messages still sees everything
  # except the bogus line.
  prev <- sink.number(type = "message")

  tmp <- tempfile("rtranscribe-av-")
  con <- file(tmp, open = "wt")
  sink(con, type = "message")

  on.exit(
    {
      if (sink.number(type = "message") != 2L) {
        sink(type = "message")
      }
      if (prev != 2L) {
        prev_con <- tryCatch(getConnection(prev), error = function(e) NULL)
        if (!is.null(prev_con)) {
          try(sink(prev_con, type = "message"), silent = TRUE)
        }
      }
      if (isOpen(con)) {
        close(con)
      }
      msgs <- tryCatch(readLines(tmp, warn = FALSE), error = function(e) {
        character()
      })
      unlink(tmp)
      # The message is printed without a trailing newline, so many copies run
      # together on one line; strip every occurrence and keep what is left.
      msgs <- trimws(gsub(av_downsample_noise, "", msgs, fixed = TRUE))
      msgs <- msgs[nzchar(msgs)]
      for (m in msgs) {
        message(m)
      }
    },
    add = TRUE
  )

  force(expr)
}

#' Read an audio file as 16 kHz mono PCM
#'
#' Decodes and resamples an audio file into the numeric vector the transcription
#' functions expect. Any format `ffmpeg` understands works (wav, mp3, m4a, flac,
#' ogg, and the audio track of video files).
#'
#' Requires the `av` package. Install it with `install.packages("av")`.
#'
#' @param path Path to an audio file.
#' @param sample_rate Target sample rate. transcribe.cpp only accepts 16000, so
#'   changing this is almost always a mistake.
#'
#' @return A numeric vector of mono samples in `[-1, 1]`.
#'
#' @examplesIf requireNamespace("av", quietly = TRUE)
#' wav <- system.file("extdata", "jfk.wav", package = "rtranscribe")
#' pcm <- transcribe_read_audio(wav)
#' length(pcm) / 16000 # duration in seconds
#'
#' @export
transcribe_read_audio <- function(path, sample_rate = 16000) {
  if (!is.character(path) || length(path) != 1L || is.na(path)) {
    cli::cli_abort("{.arg path} must be a single file path.")
  }
  path <- path.expand(path)
  if (!file.exists(path)) {
    cli::cli_abort("Audio file not found: {.path {path}}.")
  }
  rlang::check_installed(
    "av",
    reason = "for reading audio files. Alternatively, pass a numeric vector of 16 kHz mono PCM samples directly."
  )
  pcm <- without_av_noise(av::read_audio_bin(
    path,
    channels = 1L,
    sample_rate = sample_rate
  ))
  pcm <- as.numeric(pcm)

  if (length(pcm) == 0L) {
    cli::cli_abort(
      "No audio samples could be decoded from {.path {basename(path)}}."
    )
  }

  # av::read_audio_bin documents its output as signed 32-bit integer samples
  # (s32le). transcribe.cpp wants floats in [-1, 1], so rescale by the full
  # int32 range. A vector that is already within [-1, 1] is left alone, which
  # keeps the function idempotent for callers passing float PCM through.
  if (max(abs(pcm)) > 1) {
    pcm <- pcm / 2147483648 # 2^31
  }
  pcm
}

#' Audio duration in seconds
#'
#' @param x A numeric PCM vector or a path to an audio file.
#' @param sample_rate Sample rate of `x` when it is a numeric vector.
#'
#' @return A single number.
#'
#' @examplesIf FALSE
#' transcribe_audio_duration(pcm)
#'
#' @export
transcribe_audio_duration <- function(x, sample_rate = 16000) {
  if (is.character(x)) {
    x <- transcribe_read_audio(x, sample_rate = sample_rate)
  }
  length(x) / sample_rate
}
