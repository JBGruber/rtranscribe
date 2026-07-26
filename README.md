# rtranscribe

<!-- badges: start -->
[![R-CMD-check](https://github.com/JBGruber/rtranscribe/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/JBGruber/rtranscribe/actions/workflows/R-CMD-check.yaml)
[![r-universe](https://jbgruber.r-universe.dev/badges/rtranscribe)](https://jbgruber.r-universe.dev/rtranscribe)
<!-- badges: end -->

R bindings to [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp),
a C++ speech-recognition library that runs 16 model families (Whisper,
Parakeet, Moonshine, Voxtral, Canary and more) locally on the CPU.

Everything runs on your machine: no API keys, no per-minute billing, and no
audio leaves the computer. The C++ sources are bundled and compiled at install
time, so there is no separate library to install.

## Installation

You need **cmake** and a C++17 compiler. The R sources build the bundled
library, which takes a few minutes the first time.

``` r
# Debian/Ubuntu: sudo apt-get install cmake
# Fedora:        sudo dnf install cmake
# macOS:         brew install cmake

# install.packages("remotes")
remotes::install_github("JBGruber/rtranscribe")
```

Or from r-universe, which ships prebuilt binaries:

``` r
install.packages("rtranscribe", repos = "https://jbgruber.r-universe.dev")
```

## Quick start

``` r
library(rtranscribe)

# Fetch a small model (44 MB) into the package cache
model <- transcribe_download_model("whisper-tiny")

# Transcribe
res <- transcribe("interview.mp3", model)

res$text
#> [1] "And so my fellow Americans, ask not what your country can do for you..."

res
#> <transcribe_result>
#> • language: "en"
#> • timestamps: "segment"
#> • audio: 11s (12.0x real time)
#> • 1 segment, 0 words
#> ────────────────────────────────────────────────────────────
#> [00:00:00.000 -> 00:00:10.500] And so my fellow Americans, ask not what
#> your country can do for you, ask what you can do for your country.
```

Results come back as tibbles:

``` r
res$segments
#> # A tibble: 1 × 8
#>   start   end text                                speaker_id first_word ...
#>   <dbl> <dbl> <chr>                                    <int>      <int>
#> 1     0  10.5 "And so my fellow Americans, ask n…         NA          0

res$words    # word-level rows, when the model produces them
res$tokens   # token ids with confidences
res$speakers # who spoke when, after diarization
```

Any audio format `ffmpeg` reads works (wav, mp3, m4a, flac, ogg, and the audio
track of video files) via the [av](https://cran.r-project.org/package=av)
package. You can also pass a numeric vector of 16 kHz mono PCM directly.

## Choosing a model

``` r
transcribe_models()
#> # A tibble: 6 × 6
#>   name                     family     size_mb   wer downloaded note
#>   <chr>                    <chr>        <dbl> <dbl> <lgl>      <chr>
#> 1 whisper-tiny             whisper         44  7.53 TRUE       Smallest mult…
#> 2 whisper-tiny.en          whisper         44  5.72 FALSE      English-only;…
#> 3 whisper-base             whisper         81  5.12 FALSE      Multilingual,…
#> 4 whisper-large-v3-turbo   whisper        845  2.01 FALSE      Best general-…
#> 5 parakeet-tdt-0.6b-v3     parakeet       740  1.94 FALSE      Fast transduc…
#> 6 moonshine-streaming-tiny moonshine…      48  4.52 FALSE      Small streami…
```

That is a curated shortlist. `refresh = TRUE` fetches the full catalogue
(~68 models) from the Hugging Face API and appends everything else at the
bottom:

``` r
transcribe_models(refresh = TRUE)
#> # A tibble: 68 × 6
#>    name                     family  size_mb   wer downloaded note
#>    <chr>                    <chr>     <dbl> <dbl> <lgl>      <chr>
#>  1 whisper-tiny             whisper      44  7.53 TRUE       Smallest mult…
#>  …
#> 68 whisper-small.en         NA           NA    NA FALSE      NA
```

The appended rows carry only a name: the listing API does not report size, WER
or the transcribe.cpp architecture, and the repository tags are not a safe
substitute (`moonshine-streaming-*` is tagged `moonshine`, but its family is
`moonshine_streaming`). Read the authoritative architecture with
`transcribe_model_info()` after downloading. Once refreshed, any listed name
can be passed to `transcribe_download_model()`.

This is a convenience, not a limit: any GGUF converted for transcribe.cpp
works. Browse the catalogue at
[huggingface.co/handy-computer](https://huggingface.co/handy-computer) and pass
a path or URL directly.

``` r
m <- transcribe_load_model("~/models/parakeet-tdt-0.6b-v3-Q8_0.gguf")
transcribe_capabilities(m)
transcribe_supports(m, "diarization")
```

## Reusing a model

Loading a model is the expensive part. Load once, then reuse the session:

``` r
m <- transcribe_load_model(model)
s <- transcribe_session(m, n_threads = 8)

for (f in list.files("audio", full.names = TRUE)) {
  res <- transcribe_run(s, f)
  cat(basename(f), ":", res$text, "\n")
}
```

For many short clips, `transcribe_run_batch()` processes them in one dispatch:

``` r
files <- list.files("clips", pattern = "\\.wav$", full.names = TRUE)
results <- transcribe_run_batch(s, files)
vapply(results, function(r) r$text, character(1))
```

## Timestamps, translation and speakers

``` r
# Word-level timings (models that support them)
res <- transcribe_run(s, "speech.wav", timestamps = "word")
res$words

# Translate into English
transcribe_run(s, "german.wav", task = "translate", target_language = "en")

# Speaker attribution
res <- transcribe_run(s, "meeting.wav", diarize = TRUE)
res$speakers
res$segments$speaker_id
```

`res$timestamp_kind` reports the granularity you actually got, which may be
coarser than requested; check `transcribe_capabilities(m)$max_timestamp_kind`
before asking for a finer one.

## Streaming

Streaming models emit text while audio is still arriving. `committed` text is
append-only and safe to display; `full` is the model's current hypothesis and
may be revised.

``` r
m <- transcribe_load_model(transcribe_download_model("moonshine-streaming-tiny"))
s <- transcribe_session(m)

st <- transcribe_stream_begin(s, family = moonshine_streaming_options())
for (chunk in chunks) {
  transcribe_stream_feed(st, chunk)
  cat("\r", transcribe_stream_text(st)$committed)
}
transcribe_stream_finalize(st)
```

`transcribe_stream_all()` drives that whole loop over one vector, which is
handy for testing.

## Model-specific options

Some families expose knobs that do not generalise. They are passed with
`family =` and validated against the loaded model:

``` r
# Bias Whisper's decoding toward domain vocabulary
transcribe_run(s, "talk.wav", family = whisper_options(
  initial_prompt = "GESIS, Mannheim, Leibniz-Institut"
))

transcribe_accepts_options(m, whisper_options())  # TRUE for whisper models
```

Also available: `parakeet_stream_options()`,
`parakeet_buffered_stream_options()`, `moonshine_streaming_options()` and
`voxtral_realtime_options()`.

## Performance notes

- The default build targets a conservative CPU baseline so binaries run
  anywhere. For a local build tuned to your own CPU:
  `TRANSCRIBE_R_NATIVE=1 R CMD INSTALL .`
- `n_threads` in `transcribe_session()` is the main throughput knob.
- Long transcriptions can be interrupted with <kbd>Ctrl</kbd>+<kbd>C</kbd>.
- GPU backends (Vulkan, CUDA, Metal) are a build-time option that this release
  does not enable; the R API is already backend-agnostic.

## Licence

MIT. The bundled transcribe.cpp, ggml, miniz and llamafile sources are all MIT
as well — see `LICENSE.note` and `inst/licenses/`.
