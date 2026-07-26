# Running transcription -------------------------------------------------------

#' Assemble the run-params list handed to the C layer
#' @noRd
build_run_opts <- function(task = "transcribe",
                           language = NULL,
                           target_language = NULL,
                           timestamps = "auto",
                           pnc = NULL,
                           itn = NULL,
                           diarize = NULL,
                           keep_special_tags = FALSE,
                           spec_k_drafts = NULL,
                           family = NULL) {
  if (!is.null(family) && !inherits(family, "transcribe_family_options")) {
    cli::cli_abort(c(
      "{.arg family} must be created by one of the family option helpers.",
      "i" = "See {.fn whisper_options}, {.fn parakeet_stream_options}, {.fn moonshine_streaming_options}."
    ))
  }
  list(
    task = match_opt(task, c("transcribe", "translate")),
    language = language,
    target_language = target_language,
    timestamps = match_opt(timestamps, c("none", "auto", "segment", "word", "token")),
    pnc = as_tristate(pnc, "pnc"),
    itn = as_tristate(itn, "itn"),
    diarize = as_tristate(diarize, "diarize"),
    keep_special_tags = isTRUE(keep_special_tags),
    spec_k_drafts = check_scalar_int(spec_k_drafts) %||% -1L,
    family = family
  )
}

#' Transcribe audio with an existing session
#'
#' The low-level run entry point. Use this when you want to reuse one loaded
#' model and session across many calls; see [transcribe()] for the one-call
#' convenience wrapper.
#'
#' @param session A `transcribe_session` from [transcribe_session()].
#' @param audio A numeric vector of 16 kHz mono PCM samples in `[-1, 1]`, or a
#'   path to an audio file (decoded with [transcribe_read_audio()], which needs
#'   the `av` package).
#' @param task `"transcribe"` (default) or `"translate"`. Translation requires
#'   a model whose capabilities declare support for it.
#' @param language Source-language hint as a short code such as `"en"` or
#'   `"de"`. `NULL` (default) autodetects when the model supports it.
#' @param target_language Target language for `task = "translate"`.
#' @param timestamps Requested granularity: `"auto"` (default, the finest the
#'   model supports), `"none"`, `"segment"`, `"word"` or `"token"`. Asking for
#'   a granularity finer than the model can produce is an error; check
#'   [transcribe_capabilities()]`$max_timestamp_kind` first.
#' @param diarize Speaker attribution. `TRUE`/`FALSE`, or `NULL` (default) for
#'   the model's own default. Only meaningful for models where
#'   `transcribe_supports(model, "diarization")` is `TRUE`.
#' @param pnc,itn Punctuation/capitalisation and inverse text normalisation
#'   toggles. `TRUE`/`FALSE`, or `NULL` (default) for the family default.
#' @param keep_special_tags Keep special vocabulary tags such as `<|...|>` in
#'   the returned text. Defaults to `FALSE`; the unprocessed decode is always
#'   available as `result$raw_text`.
#' @param spec_k_drafts Speculative-decoding draft length. `NULL` (default)
#'   uses the family's tuned value; `0` disables it.
#' @param family Family-specific options from [whisper_options()] and friends.
#' @param interruptible Whether <kbd>Ctrl</kbd>+<kbd>C</kbd> should cancel a
#'   running transcription. Defaults to `TRUE`.
#'
#' @return A [transcribe_result] object.
#'
#' @examplesIf FALSE
#' m <- transcribe_load_model("model.gguf")
#' s <- transcribe_session(m)
#' pcm <- transcribe_read_audio("speech.wav")
#' res <- transcribe_run(s, pcm, timestamps = "word")
#' res$segments
#'
#' @seealso [transcribe()], [transcribe_run_batch()]
#' @export
transcribe_run <- function(session,
                           audio,
                           task = "transcribe",
                           language = NULL,
                           target_language = NULL,
                           timestamps = "auto",
                           diarize = NULL,
                           pnc = NULL,
                           itn = NULL,
                           keep_special_tags = FALSE,
                           spec_k_drafts = NULL,
                           family = NULL,
                           interruptible = TRUE) {
  ptr <- session_ptr(session)
  pcm <- as_pcm(audio)

  opts <- build_run_opts(
    task = task, language = language, target_language = target_language,
    timestamps = timestamps, pnc = pnc, itn = itn, diarize = diarize,
    keep_special_tags = keep_special_tags, spec_k_drafts = spec_k_drafts,
    family = family
  )

  raw <- with_native_log(cpp_run(ptr, pcm, opts, isTRUE(interruptible)))
  new_transcribe_result(raw, audio_seconds = length(pcm) / 16000)
}

#' Transcribe several clips in one call
#'
#' Runs a batch of utterances through one session. Families with a batched
#' compute path process them in a single device dispatch; others fall back to
#' running each in turn, so every model accepts this call.
#'
#' Unlike [transcribe_run()], a malformed single utterance fails only that
#' utterance: the call succeeds and the failure is reported in that element's
#' `status`.
#'
#' @inheritParams transcribe_run
#' @param audios A list of numeric PCM vectors, or a character vector of file
#'   paths.
#' @param progress Whether to show a progress bar. Defaults to `TRUE` in
#'   interactive sessions.
#'
#' @return A list of [transcribe_result] objects, one per input.
#'
#' @examplesIf FALSE
#' res <- transcribe_run_batch(s, list(pcm1, pcm2))
#' vapply(res, function(r) r$text, character(1))
#'
#' @export
transcribe_run_batch <- function(session,
                                 audios,
                                 task = "transcribe",
                                 language = NULL,
                                 target_language = NULL,
                                 timestamps = "auto",
                                 diarize = NULL,
                                 pnc = NULL,
                                 itn = NULL,
                                 keep_special_tags = FALSE,
                                 spec_k_drafts = NULL,
                                 family = NULL,
                                 interruptible = TRUE,
                                 progress = NULL) {
  ptr <- session_ptr(session)

  if (is.character(audios)) {
    audios <- as.list(audios)
  }
  if (!is.list(audios) || length(audios) == 0L) {
    cli::cli_abort("{.arg audios} must be a non-empty list of PCM vectors or file paths.")
  }

  progress <- progress %||% interactive()
  if (isTRUE(progress) && length(audios) > 1L) {
    id <- cli::cli_progress_bar("Reading audio", total = length(audios), .envir = environment())
    pcms <- vector("list", length(audios))
    for (i in seq_along(audios)) {
      pcms[[i]] <- as_pcm(audios[[i]])
      cli::cli_progress_update(id = id, .envir = environment())
    }
    cli::cli_progress_done(id = id)
  } else {
    pcms <- lapply(audios, as_pcm)
  }

  opts <- build_run_opts(
    task = task, language = language, target_language = target_language,
    timestamps = timestamps, pnc = pnc, itn = itn, diarize = diarize,
    keep_special_tags = keep_special_tags, spec_k_drafts = spec_k_drafts,
    family = family
  )

  if (isTRUE(progress)) {
    cli::cli_alert_info("Transcribing {length(pcms)} clip{?s}...")
  }
  raws <- with_native_log(cpp_run_batch(ptr, pcms, opts, isTRUE(interruptible)))

  out <- vector("list", length(raws))
  for (i in seq_along(raws)) {
    secs <- if (i <= length(pcms)) length(pcms[[i]]) / 16000 else NA_real_
    out[[i]] <- new_transcribe_result(raws[[i]], audio_seconds = secs)
  }

  failed <- vapply(out, function(r) !identical(r$status, 0L), logical(1))
  if (any(failed)) {
    cli::cli_warn(c(
      "{sum(failed)} of {length(out)} utterance{?s} failed.",
      "i" = "Inspect {.code result[[i]]$status_message} for details."
    ))
  }
  out
}

#' Transcribe audio in one call
#'
#' The high-level entry point: loads the model if needed, transcribes, and
#' returns the result. For repeated transcription with one model, load it once
#' with [transcribe_load_model()] and pass the model object (or reuse a
#' [transcribe_session()]) so it is not re-read from disk each time.
#'
#' @inheritParams transcribe_run
#' @param audio A numeric vector of 16 kHz mono PCM, or a path to an audio file.
#' @param model A path to a `.gguf` file, a `transcribe_model`, or a
#'   `transcribe_session`.
#' @param n_threads Number of CPU threads. `NULL` lets the library decide.
#'   Ignored when `model` is already a session.
#'
#' @return A [transcribe_result] object.
#'
#' @examplesIf FALSE
#' res <- transcribe("speech.wav", "model.gguf")
#' res$text
#' res$segments
#'
#' @seealso [transcribe_run()] for reusing a session
#' @export
transcribe <- function(audio,
                       model,
                       task = "transcribe",
                       language = NULL,
                       target_language = NULL,
                       timestamps = "auto",
                       diarize = NULL,
                       pnc = NULL,
                       itn = NULL,
                       keep_special_tags = FALSE,
                       spec_k_drafts = NULL,
                       family = NULL,
                       n_threads = NULL,
                       interruptible = TRUE) {
  session <- as_session(model, n_threads = n_threads)

  transcribe_run(
    session, audio,
    task = task, language = language, target_language = target_language,
    timestamps = timestamps, diarize = diarize, pnc = pnc, itn = itn,
    keep_special_tags = keep_special_tags, spec_k_drafts = spec_k_drafts,
    family = family, interruptible = interruptible
  )
}

#' Coerce a model path / model / session into a session
#' @noRd
as_session <- function(model, n_threads = NULL) {
  if (inherits(model, "transcribe_session")) {
    return(model)
  }
  if (inherits(model, "transcribe_model")) {
    return(transcribe_session(model, n_threads = n_threads))
  }
  if (is.character(model) && length(model) == 1L) {
    path <- path.expand(model)
    if (!file.exists(path)) {
      cli::cli_abort(c(
        "Model file not found: {.path {path}}.",
        "i" = "Use {.fn transcribe_download_model} to fetch one."
      ))
    }
    # One-shot path: the native session owns the model it loads, so a single
    # finalizer frees both.
    n_threads <- check_scalar_int(n_threads) %||% 0L
    sptr <- with_native_log(cpp_open(path, "auto", 0L, n_threads, "auto", 0L))
    mptr <- cpp_session_model(sptr)
    mdl <- if (is.null(mptr)) NULL else new_transcribe_model(mptr, path)
    return(new_transcribe_session(sptr, mdl))
  }
  cli::cli_abort(
    "{.arg model} must be a path to a {.file .gguf} file, a {.cls transcribe_model} or a {.cls transcribe_session}."
  )
}

#' Coerce audio input (vector or path) to a PCM vector
#' @noRd
as_pcm <- function(audio) {
  if (is.character(audio) && length(audio) == 1L) {
    return(transcribe_read_audio(audio))
  }
  check_pcm(audio)
}
