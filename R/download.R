# Model download and cache ----------------------------------------------------

# A small curated set of convenient starting points, all Q8_0 quantisations
# published under https://huggingface.co/handy-computer. Sizes and word error
# rates are the values upstream publishes in docs/models/, and `family` is the
# transcribe.cpp architecture name (which is what the *_options() helpers key
# off). Every family ships more variants and more quantisations than are listed
# here -- see transcribe_models(refresh = TRUE) for the full catalogue (which
# transcribe_download_model() also consults on its own for an unknown name), and
# note that any .gguf converted for transcribe.cpp can be passed to
# transcribe_load_model() directly.
transcribe_registry <- tibble::tibble(
  name = c(
    "whisper-tiny",
    "whisper-tiny.en",
    "whisper-base",
    "whisper-large-v3-turbo",
    "parakeet-tdt-0.6b-v3",
    "moonshine-streaming-tiny"
  ),
  repo = paste0("handy-computer/", name, "-gguf"),
  file = paste0(name, "-Q8_0.gguf"),
  family = c(
    "whisper",
    "whisper",
    "whisper",
    "whisper",
    "parakeet",
    "moonshine_streaming"
  ),
  size_mb = c(44, 44, 81, 845, 740, 48),
  wer = c(7.53, 5.72, 5.12, 2.01, 1.94, 4.52),
  note = c(
    "Smallest multilingual Whisper. Good for smoke tests.",
    "English-only; more accurate than whisper-tiny at the same size.",
    "Multilingual, still small.",
    "Best general-purpose multilingual accuracy per unit time.",
    "Fast transducer, 25 European languages, word timestamps.",
    "Small streaming model, for transcribe_stream_begin()."
  )
)

#' Query Hugging Face for every GGUF model published by an author
#'
#' Returns the same columns as `transcribe_registry`, with `family`, `size_mb`,
#' `wer` and `note` left as `NA`: the listing API does not report them, and the
#' repository tags are not a safe substitute (`moonshine-streaming-*` is tagged
#' `moonshine`, but its transcribe.cpp family is `moonshine_streaming`). The
#' authoritative family is readable with [transcribe_model_info()] once a model
#' has been downloaded.
#'
#' @noRd
hf_gguf_models <- function(user = "handy-computer", quant = "Q8_0") {
  if (!requireNamespace("httr2", quietly = TRUE)) {
    cli::cli_abort(c(
      "{.code refresh = TRUE} requires the {.pkg httr2} package.",
      "i" = 'Install it with {.run install.packages("httr2")}.'
    ))
  }

  ua <- "rtranscribe (https://github.com/JBGruber/rtranscribe)"
  req <- httr2::request("https://huggingface.co/api/models")
  req <- httr2::req_url_query(req, author = user, full = "true", limit = 100)
  req <- httr2::req_user_agent(req, ua)
  req <- httr2::req_retry(req, max_tries = 3)

  models <- list()
  repeat {
    resp <- httr2::req_perform(req)
    page <- httr2::resp_body_json(resp)
    if (length(page) == 0) {
      break
    }
    models <- c(models, page)
    # The listing is cursor-paginated through a Link header.
    nxt <- httr2::resp_link_url(resp, "next")
    if (is.null(nxt)) {
      break
    }
    req <- httr2::req_user_agent(httr2::request(nxt), ua)
  }

  rows <- lapply(models, function(m) {
    id <- m$id %||% NA_character_
    if (is.na(id)) {
      return(NULL)
    }
    files <- vapply(
      m$siblings %||% list(),
      function(s) s$rfilename %||% NA_character_,
      character(1)
    )
    gguf <- files[!is.na(files) & grepl("\\.gguf$", files)]
    if (length(gguf) == 0) {
      return(NULL)
    }
    # Prefer the requested quantisation; fall back to whatever GGUF exists.
    pick <- grep(paste0(quant, "\\.gguf$"), gguf, value = TRUE)
    list(
      name = sub("-gguf$", "", basename(id)),
      repo = id,
      file = if (length(pick)) pick[[1]] else gguf[[1]]
    )
  })
  rows <- Filter(Negate(is.null), rows)

  if (length(rows) == 0) {
    return(transcribe_registry[0, ])
  }

  out <- tibble::tibble(
    name = vapply(rows, function(r) r$name, character(1)),
    repo = vapply(rows, function(r) r$repo, character(1)),
    file = vapply(rows, function(r) r$file, character(1)),
    family = NA_character_,
    size_mb = NA_real_,
    wer = NA_real_,
    note = NA_character_
  )
  out[order(out$name), ]
}

#' Model cache directory
#'
#' Where [transcribe_download_model()] stores models. Override with the
#' `RTRANSCRIBE_CACHE` environment variable.
#'
#' @return A single path.
#'
#' @examples
#' transcribe_cache_dir()
#'
#' @export
transcribe_cache_dir <- function() {
  env <- Sys.getenv("RTRANSCRIBE_CACHE", "")
  if (nzchar(env)) {
    return(path.expand(env))
  }
  tools::R_user_dir("rtranscribe", "cache")
}

# Refreshed catalogue ---------------------------------------------------------

#' Where a refreshed catalogue is kept between sessions
#'
#' Next to the models themselves, so that clearing the cache directory clears
#' the catalogue with it.
#' @noRd
registry_cache_file <- function() {
  file.path(transcribe_cache_dir(), "model-catalogue.rds")
}

#' Append extra rows below the curated ones, dropping duplicates
#'
#' The curated annotations always win, so a stale cached catalogue can never
#' mask an updated built-in entry.
#' @noRd
registry_merge <- function(extra) {
  reg <- transcribe_registry
  if (!is.data.frame(extra) || nrow(extra) == 0 || !all(names(reg) %in% names(extra))) {
    return(reg)
  }
  extra <- extra[!extra$name %in% reg$name, names(reg), drop = FALSE]
  rbind(reg, extra)
}

#' Every model we currently know about: curated plus previously refreshed
#'
#' The on-disk catalogue is read once per session, so a name that only exists
#' in the full Hugging Face listing stays resolvable in later sessions without
#' another refresh.
#' @noRd
known_registry <- function() {
  if (!is.null(the$registry)) {
    return(the$registry)
  }
  cached <- tryCatch(
    {
      f <- registry_cache_file()
      if (file.exists(f)) readRDS(f) else NULL
    },
    error = function(e) NULL
  )
  the$registry <- registry_merge(cached)
  the$registry
}

#' Fetch the full catalogue and remember it, for this session and on disk
#'
#' @param warn Whether to warn when the fetch fails. The automatic refresh in
#'   [transcribe_download_model()] stays quiet, because its own error message
#'   follows immediately.
#' @noRd
registry_refresh <- function(warn = TRUE) {
  extra <- tryCatch(
    hf_gguf_models(),
    error = function(e) {
      if (warn) {
        cli::cli_warn(c(
          "Could not fetch the model list from Hugging Face.",
          "x" = conditionMessage(e),
          "i" = "Returning the models already known locally."
        ))
      }
      NULL
    }
  )
  # Even a failed attempt counts: one refresh per session is enough.
  the$refreshed <- TRUE
  if (is.null(extra) || nrow(extra) == 0) {
    return(known_registry())
  }

  reg <- registry_merge(extra)
  the$registry <- reg
  tryCatch(
    {
      f <- registry_cache_file()
      dir.create(dirname(f), recursive = TRUE, showWarnings = FALSE)
      saveRDS(reg, f)
    },
    # The cache is a convenience; an unwritable one must not fail the call.
    error = function(e) NULL
  )
  reg
}

#' List models known to the package
#'
#' By default this is a small curated set of GGUF models to get started with,
#' annotated with download size, published word error rate and a short note,
#' plus anything a previous `refresh = TRUE` has added: the refreshed catalogue
#' is cached in [transcribe_cache_dir()] and re-read in later sessions.
#'
#' With `refresh = TRUE` the full catalogue published under
#' [handy-computer](https://huggingface.co/handy-computer) is fetched from the
#' Hugging Face API and any models not already in the curated set are appended
#' at the bottom. Those extra rows carry only a name -- `family`, `size_mb`,
#' `wer` and `note` are `NA`, because the listing API does not report them and
#' the repository tags are not a safe substitute. Read the authoritative
#' architecture with [transcribe_model_info()] after downloading.
#'
#' Refreshing by hand is rarely necessary: [transcribe_download_model()] fetches
#' the catalogue itself when it is handed a name it does not recognise. Use it
#' to see the full list, or to pick up models published since the last refresh.
#'
#' Either way this list is a convenience, not a limit: any `.gguf` converted
#' for transcribe.cpp works with [transcribe_load_model()].
#'
#' @param refresh Whether to query Hugging Face for the full catalogue.
#'   Requires the `httr2` package and a network connection. On failure the
#'   locally known models are returned with a warning.
#'
#' @return A tibble with one row per known model: its name, family, download
#'   size, published word error rate, whether it is already cached, and a note.
#'
#' @examples
#' transcribe_models()
#' @examplesIf interactive() && requireNamespace("httr2", quietly = TRUE)
#' # The full catalogue (~68 models), curated entries first
#' transcribe_models(refresh = TRUE)
#'
#' @export
transcribe_models <- function(refresh = FALSE) {
  reg <- if (isTRUE(refresh)) registry_refresh() else known_registry()

  cache <- transcribe_cache_dir()
  reg$downloaded <- file.exists(file.path(cache, reg$file))
  reg[c("name", "family", "size_mb", "wer", "downloaded", "note")]
}

#' Look up one registry entry by name, across curated and refreshed models
#' @noRd
model_entry <- function(name) {
  reg <- known_registry()
  hit <- reg[reg$name == name, , drop = FALSE]
  if (nrow(hit) == 0) {
    return(NULL)
  }
  as.list(hit[1, ])
}

#' Refresh the catalogue once per session, then look the name up again
#'
#' Returns `NULL` when the name is still unknown afterwards, or when there is
#' nothing left to try: no `httr2`, or a refresh already happened.
#' @noRd
model_entry_refreshed <- function(name, quiet = FALSE) {
  if (isTRUE(the$refreshed) || !requireNamespace("httr2", quietly = TRUE)) {
    return(NULL)
  }
  if (!quiet) {
    cli::cli_alert_info(
      "{.val {name}} is not in the model list; checking the full catalogue."
    )
  }
  registry_refresh(warn = FALSE)
  model_entry(name)
}

#' Download a model
#'
#' Downloads a GGUF model into the package cache and returns its path. A model
#' that is already present is not re-downloaded unless `overwrite = TRUE`.
#'
#' A name that is not in the curated list is looked up in the full
#' [handy-computer](https://huggingface.co/handy-computer) catalogue (once per
#' session, and only if `httr2` is installed) before it is rejected, so the
#' newer models listed by `transcribe_models(refresh = TRUE)` can be used
#' straight away.
#'
#' @param name Either a name from [transcribe_models()], or a direct URL to a
#'   `.gguf` file.
#' @param dest Destination directory. Defaults to [transcribe_cache_dir()].
#' @param overwrite Re-download even if the file already exists.
#' @param quiet Suppress progress output.
#' @param ask If the model needs to be downloaded, ask the user to confirm
#'   the download first.
#'
#' @return The path to the downloaded file, invisibly.
#'
#' @examplesIf FALSE
#' path <- transcribe_download_model("whisper-tiny")
#' m <- transcribe_load_model(path)
#'
#' @export
transcribe_download_model <- function(
  name,
  dest = transcribe_cache_dir(),
  overwrite = FALSE,
  quiet = FALSE,
  ask = FALSE
) {
  if (!is.character(name) || length(name) != 1L || is.na(name)) {
    cli::cli_abort("{.arg name} must be a single model name or URL.")
  }

  entry <- model_entry(name)
  if (is.null(entry) && !grepl("^https?://", name)) {
    # The name may simply be newer than the curated list, so consult the full
    # catalogue before deciding it does not exist.
    entry <- model_entry_refreshed(name, quiet = quiet)
  }

  if (!is.null(entry)) {
    url <- sprintf(
      "https://huggingface.co/%s/resolve/main/%s",
      entry$repo,
      entry$file
    )
    file <- entry$file
    size_mb <- entry$size_mb
  } else if (grepl("^https?://", name)) {
    url <- name
    file <- basename(sub("\\?.*$", "", url))
    size_mb <- NA_real_
    if (!grepl("\\.gguf$", file)) {
      cli::cli_warn(
        "URL does not end in {.file .gguf}; downloading anyway as {.file {file}}."
      )
    }
  } else {
    cli::cli_abort(c(
      "Unknown model {.val {name}}.",
      "i" = "See {.fn transcribe_models} for the known names, or pass a direct URL.",
      if (!requireNamespace("httr2", quietly = TRUE)) {
        c("i" = "The full {.field handy-computer} catalogue could not be searched:
                 install {.pkg httr2} with {.run install.packages(\"httr2\")}.")
      }
    ))
  }

  dir.create(dest, recursive = TRUE, showWarnings = FALSE)
  target <- file.path(dest, file)

  if (file.exists(target) && !overwrite) {
    if (!quiet) {
      cli::cli_alert_success("Using cached model {.path {target}}.")
    }
    return(invisible(target))
  } else if (ask) {
    cli::cli_alert_info("Do you want to download {.val {name}}?")
    if (!isTRUE(utils::askYesNo(msg = NULL, default = TRUE))) {
      cli::cli_abort(
        "Use {.help transcribe_download_model} to download {.val {name}}"
      )
    }
  }

  if (!quiet) {
    sz <- if (is.na(size_mb)) "" else sprintf(" (~%s MB)", format(size_mb))
    cli::cli_alert_info("Downloading {.val {name}}{sz} to {.path {dest}}")
  }

  tmp <- paste0(target, ".part")
  on.exit(unlink(tmp), add = TRUE)

  ok <- tryCatch(
    {
      if (requireNamespace("curl", quietly = TRUE)) {
        curl::curl_download(url, tmp, quiet = quiet, mode = "wb")
      } else {
        utils::download.file(url, tmp, mode = "wb", quiet = quiet)
      }
      TRUE
    },
    error = function(e) {
      cli::cli_abort(c(
        "Download failed.",
        "x" = conditionMessage(e),
        "i" = "URL: {.url {url}}"
      ))
    }
  )

  if (!ok || !file.exists(tmp) || file.size(tmp) == 0) {
    cli::cli_abort("Download produced no data from {.url {url}}.")
  }

  file.rename(tmp, target)
  if (!quiet) {
    cli::cli_alert_success("Saved {.path {target}}.")
  }
  invisible(target)
}

#' Resolve a model argument to a path on disk
#'
#' Shared by [transcribe_load_model()] and [transcribe()]. An existing file is
#' used as is; a bare model name is fetched with [transcribe_download_model()]
#' after asking; anything else that looks like a path is a typo rather than a
#' name, and is reported as a missing file.
#' @noRd
resolve_model_path <- function(path, arg = "path") {
  if (!is.character(path) || length(path) != 1L || is.na(path)) {
    cli::cli_abort("{.arg {arg}} must be a single file path.")
  }
  path <- path.expand(path)
  if (file.exists(path)) {
    return(path)
  }
  is_path <- grepl("/", path, fixed = TRUE) ||
    grepl("\\", path, fixed = TRUE) ||
    grepl("\\.gguf$", path)
  if (is_path) {
    cli::cli_abort(c(
      "Model file not found: {.path {path}}.",
      "i" = "Use {.fn transcribe_download_model} to fetch a model, or pass a path to your own {.file .gguf} file."
    ))
  }
  transcribe_download_model(path, ask = TRUE)
}
