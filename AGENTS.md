# AGENTS.md

Orientation for coding agents working on **rtranscribe**. The README is the
user-facing document; this file is about how the package is put together and
which parts will bite you.

## What this package is

R bindings to [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp),
a C++ speech-recognition library covering 16 model families (Whisper, Parakeet,
Moonshine, Voxtral, Canary, …) in GGUF format. Everything runs locally on the
CPU — no API keys, no network at inference time.

The C/C++ sources are **vendored** into `src/transcribe-cpp/` and built from
source at install time by the upstream CMake project. There is no external
library for the user to install; only `cmake` and a C++17 compiler.

Distribution is GitHub + r-universe. **Not CRAN** yet, which is why the
"installed package size" and "compilation time" NOTEs are tolerated.

## Layout

| Path | What lives there |
| --- | --- |
| `R/` | The whole R API, ~1.9k lines, one file per concern |
| `src/transcribe_glue.cpp` | The only hand-written C++ (~1.1k lines). All `[[Rcpp::export]]` entry points |
| `src/RcppExports.cpp`, `R/RcppExports.R` | Generated — never edit by hand |
| `src/transcribe-cpp/` | Vendored upstream tree (16 MB: CPU plus the Vulkan/CUDA/Metal sources, only CPU is compiled by default), plus `VENDOR` provenance |
| `src/Makevars.in`, `Makevars.win.in` | Templates; `configure` substitutes `@PKG_LIBS@` / `@VENDOR_INC@` |
| `configure`, `cleanup` | Drive the CMake build and tear it down. `.win` variants are unproven |
| `tools/vendor.sh` | Re-syncs the vendored tree from an upstream ref |
| `tests/testthat/` | 7 test files plus `helper-rtranscribe.R`, which holds the model-gating skips |
| `inst/extdata/` | `jfk.wav` (~11 s, offline tests) and `german.wav` (translation test) |
| `plan.md` | Test plan for the unverified CUDA backend on an RTX 3060 machine (it previously held the original build plan, which the code has superseded) |

### R file map

| File | Contents |
| --- | --- |
| `rtranscribe-package.R` | `.onLoad`/`.onAttach`, the package-state env `the` |
| `model.R` | `transcribe_load_model()`, capabilities, model info, tokenizer |
| `session.R` | `transcribe_session()`, limits, print method |
| `run.R` | `build_run_opts()`, `transcribe_run()`, `transcribe_run_batch()`, the one-shot `transcribe()` |
| `stream.R` | Incremental API: `_begin` / `_feed` / `_finalize` / `_reset` / `_text` / `_state`, plus `transcribe_stream_all()` |
| `family.R` | `whisper_options()` and the four streaming option constructors |
| `result.R` | `transcribe_result` class + `print`/`format`/`as.character`/`as.data.frame` |
| `download.R` | The static `transcribe_registry` tibble, `transcribe_models()`, HF catalogue fetch, downloader |
| `audio.R` | `transcribe_read_audio()` via `av`, `without_av_noise()` |
| `devices.R` | Version, device listing, backend probe, `transcribe_set_verbosity()` |
| `utils.R` | Argument validators, the native-log drain, timestamp formatting |

## Architecture

Three layers, and it matters which one a change belongs in:

1. **R API** (`R/*.R`) — functional + S3, no R6. Errors and messages go through
   `cli`. Tabular results are tibbles. Argument validation happens here, before
   the native call, so users get an R-level error rather than a C-level one.
2. **Rcpp glue** (`src/transcribe_glue.cpp`) — marshalling only. It converts
   strings to enums, builds the size-aware option structs, wraps handles, and
   translates statuses into R conditions. No transcription logic.
3. **Vendored C++** (`src/transcribe-cpp/`) — upstream, unmodified. Do not
   patch it in place; changes belong upstream and come back through
   `tools/vendor.sh`.

### Handles

Models and sessions are R external pointers, not `Rcpp::XPtr` (see
`transcribe_glue.cpp:157-241`). Reasons, in case someone is tempted to
"simplify" it:

- The finalizer must be the library's own `transcribe_model_free` /
  `transcribe_session_free`, never `delete`.
- `Rcpp::XPtr` will not compile with a `NULL` finalizer, and **borrowed**
  handles need exactly that: `cpp_session_model()` hands out a model pointer
  the session owns.
- Each pointer carries a **tag** (`rtranscribe_model` / `rtranscribe_session`).
  Passing a session where a model is expected becomes an R error instead of a
  wild dereference.
- A borrowed model handle stashes the owning session in the external pointer's
  `prot` slot, so the session cannot be collected out from under it.
- Handles do not survive `save()`/`load()`; the address comes back `NULL` and
  `get_model()`/`get_session()` raise a message that says so.

### Logging

`transcribe.cpp` writes diagnostics to stderr by default. The package installs
a buffered sink at load time (`transcribe_set_verbosity()` in `.onLoad`,
*before* any model exists, as upstream requires). The callback can fire on ggml
worker threads, **so it must never touch R** — it appends under a mutex, and
`flush_native_log()` (`utils.R:81`) drains and re-emits through `cli` after the
native call returns. `with_native_log()` wraps calls so the drain happens even
on error.

### Interrupts

Long runs are Ctrl-C-able. The mechanism (`transcribe_glue.cpp:334-380`):
`interrupt_pending()` probes via `R_ToplevelExec`, an abort callback tells the
library to stop, and `g_interrupted` is re-raised after the native call
unwinds. See the gotcha below for why the flag is not optional.

## Build

`configure` is a POSIX `sh` script that:

1. Locates `cmake` (helpful per-distro error if missing).
2. Reads `R CMD config CC`/`CXX` and **splits off the first word** (gotcha
   below).
3. Probes for any opted-in GPU backend's build dependencies (see below), then
   runs the upstream CMake with a static, no-OpenMP, no-tests configuration
   into `src/transcribe-cpp/build`, installing to `src/transcribe-cpp/install`.
4. Parses `lib/transcribe-link.json` with `sed` (no JSON package available at
   configure time) to get the archive list and system libs, falling back to a
   glob if the manifest shape changes.
5. Emits `src/Makevars` from `Makevars.in`.

Link line specifics:

- GNU ld gets `-Wl,--start-group … --end-group` so inter-archive ordering is
  irrelevant, plus `-Wl,--exclude-libs,ALL` to keep the ~130 exported
  `transcribe_*` symbols out of the shared object's dynamic table (avoids
  colliding with any other package embedding ggml). The `--exclude-libs` flag
  is **compile-tested before use** — not every linker takes it.
- macOS gets a plain archive listing; `ld64` resolves in multiple passes and
  rejects `--start-group`.

Environment knobs:

- `TRANSCRIBE_R_NATIVE=1` — `-march=native`. Local builds only; the binary is
  not portable. Default is `TRANSCRIBE_X86_CONSERVATIVE=ON`.
- `TRANSCRIBE_R_JOBS=N` — parallel compile jobs.
- `CMAKE` — path to a specific cmake.
- `TRANSCRIBE_R_VULKAN=1` / `TRANSCRIBE_R_CUDA=1` / `TRANSCRIBE_R_METAL=1` —
  compile in that backend. Off by default.
- `TRANSCRIBE_R_CUDA_ARCHS` — pass-through for `CMAKE_CUDA_ARCHITECTURES`.
  Upstream's default is `native`, which is right for a source install and
  wrong for anything you plan to move to another machine.

### GPU backends

Off by default for a distribution reason, not a capability one: the CPU build
needs only a compiler, while each GPU backend needs an SDK at build time and
drivers at run time, so none of them can be in a binary that has to install
everywhere. Nothing above the build layer changes — the compiled-in set is what
`transcribe_load_model(backend =)` can accept. Note that
`transcribe_backend_available()` is a *device* probe, not a build probe: it
walks the registered devices, so it answers `FALSE` on a Vulkan-enabled build
running where no Vulkan driver exists.

Two halves have to agree, and they are in different files:

1. `tools/vendor.sh` — the allowlist decides which backend sources are in the
   tree at all (`ggml-cpu`, `ggml-vulkan`, `ggml-cuda`, `ggml-metal`).
2. `configure` — `require_backend_sources()` checks the directory is there,
   then a dependency probe runs before CMake: `glslc` plus a
   `#include <vulkan/vulkan.h>` compile test for Vulkan, `nvcc` (or `CUDACXX`)
   for CUDA, `uname -s` for Metal. Each failure prints a per-distribution
   install hint, because the CMake-level failure for a missing `glslc` is
   unreadable.

Verified: **CPU** and **Vulkan** (Linux). **CUDA** and **Metal** are wired but
have never been built — no hardware here. Treat their link lines as unproven.

`ggml-sycl` and `ggml-openvino` stay out of the tree deliberately: they hold
the only Apache-2.0 code upstream, and excluding them is what keeps the
compiled path uniformly MIT (`LICENSE.note`). Do not add them to the allowlist
without redoing the licence bundle.

### Re-vendoring upstream

```sh
tools/vendor.sh https://github.com/handy-computer/transcribe.cpp v0.2.0
```

The script copies every `ggml-*` backend directory and then prunes with an
**allowlist** (`ggml-cpu`, `ggml-vulkan`, `ggml-cuda`, `ggml-metal` survive,
anything else is deleted), so a new upstream backend cannot silently slip into
the tarball. Sources being present is not the same as being compiled — see the
GPU backends section above. It records
url/ref/describe/sha/abihash in `src/transcribe-cpp/VENDOR`. Currently pinned at
`v0.1.3-4-gb6a6aca`, abihash `d67a9bd78b964445`.

After re-vendoring, check `include/transcribe.abihash` against the recorded
value — a change there means the glue may need updating.

## Non-obvious constraints

These each cost real time to discover:

- **`R CMD config CXX` returns compiler *plus* standard flag** (`g++
  -std=gnu++20`). CMake rejects that for `CMAKE_CXX_COMPILER`. `configure`
  splits the first word and lets upstream CMake pick the standard (C++17).
- **`Rcpp::compileAttributes()` says "pkgdir must refer to the directory
  containing an R package" for a missing NAMESPACE**, not just a missing
  DESCRIPTION — identical message for both.
- **`R_ToplevelExec` consumes the interrupt it catches.** A later
  `R_CheckUserInterrupt()` sees nothing, so the naive pattern silently returns
  partial results instead of aborting. Record a flag and re-raise after
  unwinding.
- **Upstream's `transcribe_log_level` enum is not severity-ordered**
  (`INFO=1, WARN=2, ERROR=3, DEBUG=4`). A `level <= threshold` filter drops
  errors before warnings. Use `severity_rank()`.
- **Option structs are size-aware**: a `struct_size` field of 0 is a bug. Call
  the corresponding `_init()` before filling one in.
- **A reinstall reuses `src/rtranscribe.so`.** `make` sees it newer than the
  glue sources and does nothing, so switching backends (or any change confined
  to the vendored tree) silently keeps the previously linked shared object —
  the install log says `make: Nothing to be done for 'all'` and everything else
  looks like a success. `cleanup` now removes `src/*.o` and `src/*.so`; run it
  (or `R CMD INSTALL --preclean`) when changing the backend set.
- **`transcribe-link.json` does not carry ggml-cuda's dependencies.** The
  manifest is reconstructed from `libtranscribe`'s *own* link list, and
  cudart/cublas/the driver library are `PRIVATE` to the `ggml-cuda` target, so
  a static CUDA build links with undefined CUDA symbols unless `configure`
  appends them — which it does, in the block after `SYSLIBS` is assembled.
  Vulkan and Metal need no such fixup: `cmake/transcribe-install.cmake` special
  cases those two (`-lvulkan`, the Metal frameworks) and not CUDA.
- **`av::read_audio_bin()` returns signed 32-bit samples** (`s32le`), so
  normalise by `2^31`, not `2^15`.
- **GC protection**: an unprotected SEXP is collectable while a *later*
  `List::create` argument allocates. `mk_utf8_str()` returns an
  `Rcpp::CharacterVector` rather than a bare SEXP for exactly this reason.
  Verify changes here under `gctorture(TRUE)`.
- **UTF-8**: strings from the library are marshalled with
  `Rf_mkCharLenCE(..., CE_UTF8)`. Several are borrowed pointers valid only until
  the next library call — copy before returning.
- **Do not derive `family` from Hugging Face tags.** `moonshine-streaming-tiny`
  is tagged `moonshine`, but its transcribe.cpp family is `moonshine_streaming`,
  and `family` selects which `*_options()` helper applies. The authoritative
  value comes from `transcribe_model_info()` on a downloaded model.

### The `av` message

`av` prints `Insufficient memory to recode all samples` once per decoded frame
whenever the target rate is below the file's native rate — roughly 1150 times
for a 30 s 44.1→16 kHz file, i.e. on almost every real input. It is a false
positive: `av` compares the *output* sample count against the *input* count,
which downsampling always reduces. No audio is lost.

It is emitted with `REprintf`, so neither `suppressWarnings()` nor
`av::av_log_level()` touches it — only a **message sink** can. That is what
`without_av_noise()` (`R/audio.R:35`) does: it redirects, filters the known
string, and re-emits everything else. It saves and restores any pre-existing
sink via `getConnection()`, because R's message sink is a single destination
rather than a stack and clobbering it breaks knitr/Quarto.

Upstream: [ropensci/av#27](https://github.com/ropensci/av/issues/27). A fix
exists in the local clone at `~/Documents/GitHub/av`, branch
`fix-resample-buffer-warning` (sizes the buffer with `swr_get_out_samples()`),
not yet pushed. **Keep the filter regardless** — it will be needed for everyone
on CRAN's `av` until that lands and ships.

## Conventions

- Roxygen 7 with markdown; `NAMESPACE` and `man/` are generated. Run
  `devtools::document()` (or the `btw` doc tool) after touching roxygen.
- After editing `[[Rcpp::export]]` signatures, run `Rcpp::compileAttributes()`
  before documenting.
- Every exported function is documented with a runnable or `@examplesIf`-guarded
  example. `@examplesIf FALSE` for anything needing a model.
- User-visible text goes through `cli`. `cli::cli_abort()` for errors, with an
  `i` bullet pointing at the fix where there is one.
- Tabular output is always a tibble.
- `the` (`rtranscribe-package.R:12`) is the package-state environment:
  `backends_ok`, `verbosity`, and the cached refreshed model `registry`.
- Argument validators live in `utils.R` (`match_opt`, `as_tristate`,
  `check_scalar_int`, `check_pcm`). Reuse them rather than hand-rolling checks.

## Testing

```r
devtools::load_all(); devtools::test()
```

The default suite is **offline and model-free** — it covers argument
validation, handle type-safety, registry logic, result shaping and the av
filter. Tests needing a real model skip unless you set:

```sh
RTRANSCRIBE_TEST_MODEL=~/.cache/R/rtranscribe/whisper-tiny-Q8_0.gguf
RTRANSCRIBE_TEST_STREAM_MODEL=~/.cache/R/rtranscribe/moonshine-streaming-tiny-Q8_0.gguf
RTRANSCRIBE_TEST_DOWNLOAD=1   # or let the suite fetch them
```

Two models are needed because whisper-tiny can neither stream nor diarize.
Models come from
`https://huggingface.co/handy-computer/<name>-gguf/resolve/main/<name>-Q8_0.gguf`.

CI: `R-CMD-check.yaml` on every push (ubuntu release/devel/oldrel + macOS;
no Windows entry, deliberately). `test-with-model.yaml` runs the gated suite
weekly with a model cache.

**`R CMD check` hanging at "checking package dependencies"** is almost always
a Bioconductor entry in `options(repos)` reaching out over the network. Work
around it with `R_PROFILE_USER` pointing at a profile that sets a valid **empty
local repo** — a nonexistent path makes check error out hard instead.

Current status: **1 NOTE** (installed size / compilation time), no warnings.

## State and limitations

- **One commit so far** (`initial commit` on `main`). `test.mp4` and
  `snowflake.log` at the root are scratch and are gitignored.
- **Windows is unsupported.** `DESCRIPTION` declares `OS_type: unix`.
  `configure.win` and `Makevars.win.in` exist as a starting point but have never
  been run. Dropping `OS_type` and adding the Windows CI matrix entry are one
  change, not two.
- **CPU by default, GPU opt-in.** Vulkan is tested on Linux; CUDA and Metal are
  wired up but unbuilt for want of hardware. Distributed r-universe binaries
  stay CPU-only, so a GPU build always means a source install.
- **Diarization is unverified end-to-end.** It is implemented and wired
  through, but the smallest diarization-capable model is over 1 GB, so no test
  exercises it.
- The `transcribe_registry` tibble is 6 curated models. `refresh = TRUE`
  appends the rest of the `handy-computer` catalogue (~68 total) with `family`,
  `size_mb`, `wer` and `note` as `NA`, and caches the result in `the$registry`
  so appended names become resolvable for download.
