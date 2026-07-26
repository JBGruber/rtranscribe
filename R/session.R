# Sessions --------------------------------------------------------------------

#' Create a transcription session
#'
#' A session holds the decoding state for one stream of audio. Create one
#' session per concurrent transcription; a session may be reused for any number
#' of sequential runs, which avoids re-loading the model each time.
#'
#' The session keeps a reference to `model`, so the model stays alive for as
#' long as the session does regardless of garbage-collection order.
#'
#' @param model A `transcribe_model` from [transcribe_load_model()].
#' @param n_threads Number of CPU threads for ops that run on CPU. `NULL`
#'   (default) lets the library pick.
#' @param kv_type Data type for the attention K/V cache: `"auto"` (default),
#'   `"f32"` or `"f16"`.
#' @param n_ctx Optional cap on the decoder context window, in tokens. `NULL`
#'   (default) uses the model's own maximum. This is a memory knob: lowering it
#'   can lower the maximum audio length the session accepts.
#'
#' @return A `transcribe_session` object.
#'
#' @examplesIf FALSE
#' m <- transcribe_load_model("model.gguf")
#' s <- transcribe_session(m, n_threads = 4)
#' transcribe_session_limits(s)
#'
#' @seealso [transcribe_run()], [transcribe_session_limits()]
#' @export
transcribe_session <- function(model, n_threads = NULL, kv_type = "auto", n_ctx = NULL) {
  ptr <- model_ptr(model)
  n_threads <- check_scalar_int(n_threads) %||% 0L
  n_ctx <- check_scalar_int(n_ctx) %||% 0L
  kv_type <- match_opt(kv_type, c("auto", "f32", "f16"))

  sptr <- with_native_log(cpp_session_init(ptr, n_threads, kv_type, n_ctx))
  new_transcribe_session(sptr, model)
}

#' @noRd
new_transcribe_session <- function(ptr, model) {
  structure(
    # `model` is stored to keep the model reachable: the native session borrows
    # the model and would dangle if R collected the model first.
    list(ptr = ptr, model = model),
    class = "transcribe_session"
  )
}

#' @noRd
session_ptr <- function(x, arg = "session") {
  if (inherits(x, "transcribe_session")) {
    return(x$ptr)
  }
  if (inherits(x, "transcribe_stream")) {
    return(x$session$ptr)
  }
  cli::cli_abort("{.arg {arg}} must be a {.cls transcribe_session}, not {.obj_type_friendly {x}}.")
}

#' Effective limits of a session
#'
#' Reports the context window and maximum audio length actually in force for a
#' session, which may be lower than the model-level maximum when `n_ctx` was
#' capped in [transcribe_session()].
#'
#' @param session A `transcribe_session`.
#'
#' @return A list with `effective_n_ctx` (tokens), `effective_max_audio`
#'   (seconds, `Inf` when unbounded) and `max_kv_bytes`.
#'
#' @examplesIf FALSE
#' transcribe_session_limits(s)
#'
#' @export
transcribe_session_limits <- function(session) {
  lim <- cpp_session_limits(session_ptr(session))
  lim$effective_max_audio <- if (lim$effective_max_audio_ms > 0) {
    lim$effective_max_audio_ms / 1000
  } else {
    Inf
  }
  lim$effective_max_audio_ms <- NULL
  lim
}

#' @export
print.transcribe_session <- function(x, ...) {
  st <- cpp_stream_state(x$ptr)
  cli::cli_text("{.cls transcribe_session} on {.strong {x$model$arch}}")
  cli::cli_bullets(c("*" = "stream state: {.val {st$state}}"))
  lim <- tryCatch(transcribe_session_limits(x), error = function(e) NULL)
  if (!is.null(lim)) {
    ctx <- if (lim$effective_n_ctx > 0) as.character(lim$effective_n_ctx) else "unbounded"
    aud <- if (is.finite(lim$effective_max_audio)) {
      paste0(round(lim$effective_max_audio), "s")
    } else {
      "unbounded"
    }
    cli::cli_bullets(c("*" = "context: {ctx} tokens, max audio: {aud}"))
  }
  invisible(x)
}

#' @noRd
`%||%` <- function(x, y) if (is.null(x)) y else x
