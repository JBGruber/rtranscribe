# Family-specific options -----------------------------------------------------

#' @noRd
new_family_options <- function(kind, slot, ...) {
  opts <- list(...)
  opts <- opts[!vapply(opts, is.null, logical(1))]
  structure(
    c(list(kind = kind, slot = slot), opts),
    class = "transcribe_family_options"
  )
}

#' Whisper decoding options
#'
#' Family-specific knobs for Whisper models, passed as the `family` argument of
#' [transcribe_run()] or [transcribe()]. Whisper ignores the generic `pnc` and
#' `itn` toggles.
#'
#' Thresholds can be disabled individually by passing `Inf` (for
#' `compression_ratio_thold` and `no_speech_thold`) or `-Inf` (for
#' `logprob_thold`), which reproduces the "all thresholds off" behaviour of
#' HuggingFace's `generate()`.
#'
#' @param initial_prompt Free text used to bias decoding, for example a list of
#'   proper nouns likely to appear in the audio.
#' @param prompt_tokens Integer token ids to use verbatim instead of
#'   `initial_prompt`. Must not include the `<|startofprev|>` marker.
#' @param prompt_condition How the initial prompt composes with
#'   `condition_on_prev_tokens` on long-form runs: `"first_segment"` (default)
#'   or `"all_segments"`. The latter requires `condition_on_prev_tokens = TRUE`.
#' @param condition_on_prev_tokens Carry the previous chunk's tokens into the
#'   next chunk's prefix.
#' @param max_prev_context_tokens Cap for carried previous tokens (default 223).
#' @param temperature First-tier sampling temperature (default 0).
#' @param temperature_inc Temperature step for the fallback loop (default 0.2).
#' @param compression_ratio_thold Reject a decode whose gzip compression ratio
#'   exceeds this (default 2.4).
#' @param logprob_thold Reject a decode whose average log-probability falls
#'   below this (default -1).
#' @param no_speech_thold No-speech probability above which a chunk is treated
#'   as silence (default 0.6).
#' @param seed Sampler seed for `temperature > 0`. `0` is nondeterministic.
#' @param max_initial_timestamp Cap on the first emitted timestamp, in seconds.
#'
#' @return A `transcribe_family_options` object.
#'
#' @examplesIf FALSE
#' transcribe_run(s, pcm, family = whisper_options(
#'   initial_prompt = "Kubernetes, PostgreSQL, nginx",
#'   temperature = 0
#' ))
#'
#' @export
whisper_options <- function(initial_prompt = NULL,
                            prompt_tokens = NULL,
                            prompt_condition = NULL,
                            condition_on_prev_tokens = NULL,
                            max_prev_context_tokens = NULL,
                            temperature = NULL,
                            temperature_inc = NULL,
                            compression_ratio_thold = NULL,
                            logprob_thold = NULL,
                            no_speech_thold = NULL,
                            seed = NULL,
                            max_initial_timestamp = NULL) {
  if (!is.null(prompt_condition)) {
    prompt_condition <- match_opt(prompt_condition, c("first_segment", "all_segments"))
  }
  if (!is.null(prompt_tokens)) {
    prompt_tokens <- as.integer(prompt_tokens)
  }
  new_family_options(
    "whisper_run", "run",
    initial_prompt = initial_prompt,
    prompt_tokens = prompt_tokens,
    prompt_condition = prompt_condition,
    condition_on_prev_tokens = condition_on_prev_tokens,
    max_prev_context_tokens = max_prev_context_tokens,
    temperature = temperature,
    temperature_inc = temperature_inc,
    compression_ratio_thold = compression_ratio_thold,
    logprob_thold = logprob_thold,
    no_speech_thold = no_speech_thold,
    seed = seed,
    max_initial_timestamp = max_initial_timestamp
  )
}

#' Streaming options for specific model families
#'
#' Family-specific streaming knobs, passed as the `family` argument of
#' [transcribe_stream_begin()]. Each helper targets one model family; use
#' [transcribe_accepts_options()] to check that the loaded model accepts a
#' given kind before passing it.
#'
#' @param att_context_right Right-context frames for cache-aware Parakeet
#'   streaming. `-1` means the model default.
#' @param left_ms,chunk_ms,right_ms Buffered-streaming window for Parakeet, in
#'   milliseconds.
#' @param min_decode_interval_ms Minimum wall-clock interval between decoder
#'   invocations, which throttles compute for autoregressive streaming models.
#' @param num_delay_tokens Voxtral realtime decode delay, in tokens.
#'
#' @return A `transcribe_family_options` object.
#'
#' @examplesIf FALSE
#' transcribe_stream_begin(s, family = parakeet_stream_options(att_context_right = 13))
#'
#' @name family_stream_options
NULL

#' @rdname family_stream_options
#' @export
parakeet_stream_options <- function(att_context_right = NULL) {
  new_family_options("parakeet_stream", "stream", att_context_right = att_context_right)
}

#' @rdname family_stream_options
#' @export
parakeet_buffered_stream_options <- function(left_ms = NULL, chunk_ms = NULL, right_ms = NULL) {
  new_family_options(
    "parakeet_buffered_stream", "stream",
    left_ms = left_ms, chunk_ms = chunk_ms, right_ms = right_ms
  )
}

#' @rdname family_stream_options
#' @export
moonshine_streaming_options <- function(min_decode_interval_ms = NULL) {
  new_family_options(
    "moonshine_streaming", "stream",
    min_decode_interval_ms = min_decode_interval_ms
  )
}

#' @rdname family_stream_options
#' @export
voxtral_realtime_options <- function(num_delay_tokens = NULL, min_decode_interval_ms = NULL) {
  new_family_options(
    "voxtral_realtime", "stream",
    num_delay_tokens = num_delay_tokens,
    min_decode_interval_ms = min_decode_interval_ms
  )
}

#' Check whether a model accepts a set of family options
#'
#' Family options are only valid for the model family they were written for,
#' and only in the slot (run or stream) they belong to. Probe before passing
#' them, so a mismatch becomes a clear message rather than an error from the
#' native layer.
#'
#' @param model A `transcribe_model` or `transcribe_session`.
#' @param options A `transcribe_family_options` object.
#'
#' @return A single logical.
#'
#' @examplesIf FALSE
#' transcribe_accepts_options(m, whisper_options(initial_prompt = "hi"))
#'
#' @export
transcribe_accepts_options <- function(model, options) {
  if (!inherits(options, "transcribe_family_options")) {
    cli::cli_abort("{.arg options} must come from a family option helper such as {.fn whisper_options}.")
  }
  if (inherits(model, "transcribe_session")) {
    model <- model$model
  }
  if (is.null(model)) {
    return(NA)
  }
  cpp_model_accepts_ext_kind(model_ptr(model), options$slot, options$kind)
}

#' @export
print.transcribe_family_options <- function(x, ...) {
  cli::cli_text("{.cls transcribe_family_options} {.strong {x$kind}} ({x$slot} slot)")
  fields <- x[setdiff(names(x), c("kind", "slot"))]
  if (length(fields) == 0L) {
    cli::cli_bullets(c("i" = "all defaults"))
  } else {
    for (nm in names(fields)) {
      cli::cli_bullets(c("*" = "{nm}: {.val {fields[[nm]]}}"))
    }
  }
  invisible(x)
}
