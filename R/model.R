# Model handles ---------------------------------------------------------------

#' Load a transcription model
#'
#' Loads a GGUF speech-recognition model from disk. The returned object holds an
#' external pointer to native memory: it cannot be saved to disk or sent to
#' another R process, and it is freed automatically when garbage collected.
#'
#' @param path Path to a `.gguf` model file.
#' @param backend Compute backend to request: `"auto"` (default), `"cpu"`,
#'   `"cpu_accel"`, `"metal"`, `"vulkan"` or `"cuda"`. `"auto"` uses the first
#'   GPU device that initialises and falls back to the CPU; naming a GPU
#'   backend is an assertion and errors if it is unavailable. The default build
#'   is CPU-only — a GPU backend has to be compiled in at install time with
#'   `TRANSCRIBE_R_VULKAN=1`, `TRANSCRIBE_R_CUDA=1` or `TRANSCRIBE_R_METAL=1`
#'   (see the README), and needs a working driver at run time —
#'   [transcribe_backend_available()] checks both.
#' @param gpu_device Multi-GPU selector. `0` (default) means "first device of
#'   the chosen kind"; a positive value selects the device at that index in
#'   [transcribe_devices()].
#'
#' @return A `transcribe_model` object.
#'
#' @examplesIf FALSE
#' m <- transcribe_load_model("~/models/whisper-tiny-Q8_0.gguf")
#' m
#'
#' @seealso [transcribe_session()], [transcribe_capabilities()], [transcribe()]
#' @export
transcribe_load_model <- function(path, backend = "auto", gpu_device = 0L) {
  if (!is.character(path) || length(path) != 1L || is.na(path)) {
    cli::cli_abort("{.arg path} must be a single file path.")
  }
  path <- path.expand(path)
  if (!file.exists(path)) {
    cli::cli_abort(c(
      "Model file not found: {.path {path}}.",
      "i" = "Use {.fn transcribe_download_model} to fetch a model, or pass a path to your own {.file .gguf} file."
    ))
  }
  backend <- match_opt(backend, c("auto", "cpu", "cpu_accel", "metal", "vulkan", "cuda"))
  gpu_device <- check_scalar_int(gpu_device, allow_null = FALSE)

  if (!backend %in% c("auto", "cpu", "cpu_accel") && !cpp_backend_available(backend)) {
    cli::cli_abort(c(
      "No {.val {backend}} device is available.",
      "i" = "Available devices: {.val {transcribe_devices()$kind}}.",
      "i" = "Either this install was not built with {.val {backend}} support \\
             (re-install from source with {.code TRANSCRIBE_R_{toupper(backend)}=1}), \\
             or no {.val {backend}} driver is present on this machine."
    ))
  }

  ptr <- with_native_log(cpp_model_load(path, backend, gpu_device))
  new_transcribe_model(ptr, path)
}

#' @noRd
new_transcribe_model <- function(ptr, path) {
  info <- cpp_model_info(ptr)
  structure(
    list(
      ptr = ptr,
      path = path,
      arch = info$arch,
      variant = info$variant,
      backend = info$backend
    ),
    class = "transcribe_model"
  )
}

#' @noRd
model_ptr <- function(x, arg = "model") {
  if (inherits(x, "transcribe_model")) {
    return(x$ptr)
  }
  cli::cli_abort("{.arg {arg}} must be a {.cls transcribe_model}, not {.obj_type_friendly {x}}.")
}

#' Model capabilities and feature probes
#'
#' `transcribe_capabilities()` reports the semantic properties a model declares:
#' supported languages, the finest timestamp granularity it can produce, whether
#' it can translate or stream, and its maximum input length.
#'
#' `transcribe_supports()` probes a single named feature.
#'
#' @param model A `transcribe_model` from [transcribe_load_model()].
#' @param feature One of `"initial_prompt"`, `"temperature_fallback"`,
#'   `"long_form"`, `"cancellation"`, `"pnc"`, `"itn"` or `"diarization"`.
#'
#' @return `transcribe_capabilities()` returns a list. `transcribe_supports()`
#'   returns a single logical.
#'
#' @examplesIf FALSE
#' m <- transcribe_load_model("model.gguf")
#' transcribe_capabilities(m)
#' transcribe_supports(m, "diarization")
#'
#' @export
transcribe_capabilities <- function(model) {
  caps <- cpp_model_capabilities(model_ptr(model))
  caps$max_audio <- if (caps$max_audio_ms > 0) caps$max_audio_ms / 1000 else Inf
  caps$max_audio_ms <- NULL
  caps
}

#' @rdname transcribe_capabilities
#' @export
transcribe_supports <- function(model, feature) {
  feature <- match_opt(feature, c(
    "initial_prompt", "temperature_fallback", "long_form",
    "cancellation", "pnc", "itn", "diarization"
  ))
  cpp_model_supports(model_ptr(model), feature)
}

#' Model metadata
#'
#' Reads identity metadata from the model's GGUF header.
#'
#' @param model A `transcribe_model`.
#' @param key Optional single GGUF metadata key (for example `"general.name"`
#'   or `"general.license"`). When `NULL` (default) a standard set of keys is
#'   returned.
#'
#' @return A list of metadata values, or a single string when `key` is given.
#'
#' @examplesIf FALSE
#' transcribe_model_info(m)
#' transcribe_model_info(m, "general.license")
#'
#' @export
transcribe_model_info <- function(model, key = NULL) {
  ptr <- model_ptr(model)
  if (!is.null(key)) {
    return(cpp_model_meta(ptr, key))
  }
  info <- cpp_model_info(ptr)
  keys <- c(
    name = "general.name",
    author = "general.author",
    organization = "general.organization",
    license = "general.license",
    license_name = "general.license.name",
    license_link = "general.license.link",
    repo_url = "general.repo_url"
  )
  meta <- lapply(keys, function(k) cpp_model_meta(ptr, k))
  meta <- meta[vapply(meta, nzchar, logical(1))]
  c(info, list(path = model$path), meta)
}

#' @export
print.transcribe_model <- function(x, ...) {
  cli::cli_text("{.cls transcribe_model} {.strong {x$arch}}{if (nzchar(x$variant)) paste0(' / ', x$variant) else ''}")
  cli::cli_bullets(c("*" = "file:    {.path {basename(x$path)}}"))
  cli::cli_bullets(c("*" = "backend: {.val {x$backend}}"))
  caps <- tryCatch(transcribe_capabilities(x), error = function(e) NULL)
  if (!is.null(caps)) {
    nl <- length(caps$languages)
    cli::cli_bullets(c("*" = "languages: {if (nl == 0) 'not advertised' else nl}"))
    feats <- c(
      if (caps$supports_translate) "translate",
      if (caps$supports_streaming) "streaming",
      if (transcribe_supports(x, "diarization")) "diarization",
      if (caps$supports_language_detect) "language detection"
    )
    cli::cli_bullets(c("*" = "supports: {if (length(feats)) paste(feats, collapse = ', ') else 'transcription only'}"))
    cli::cli_bullets(c("*" = "timestamps up to: {.val {caps$max_timestamp_kind}}"))
  }
  invisible(x)
}

#' Tokenize text with a model's vocabulary
#'
#' @param model A `transcribe_model`.
#' @param text A single string of plain UTF-8 text. Special tokens are not
#'   recognised and would be encoded piece-by-piece.
#'
#' @return An integer vector of token ids.
#'
#' @examplesIf FALSE
#' transcribe_tokenize(m, "hello world")
#'
#' @export
transcribe_tokenize <- function(model, text) {
  if (!is.character(text) || length(text) != 1L || is.na(text)) {
    cli::cli_abort("{.arg text} must be a single string.")
  }
  cpp_tokenize(model_ptr(model), text)
}
