# Plan: verifying the CUDA backend on the RTX 3060 machine

> The opt-in GPU build landed with Vulkan proven and CUDA **compiled by nobody**.
> This plan is what to run on the NVIDIA box to close that gap, in the order
> that fails fastest, plus the fixes for the failures that are actually likely.
> The previous contents of this file (the original from-scratch build plan) are
> superseded by the code and by `AGENTS.md`.

## Where things stand

`configure` grew three opt-in knobs — `TRANSCRIBE_R_VULKAN`, `TRANSCRIBE_R_CUDA`,
`TRANSCRIBE_R_METAL` — and `tools/vendor.sh:78` now keeps `ggml-cuda` in the
vendored tree. On the AMD box the Vulkan build is verified end to end: an
iGPU shows up in `transcribe_devices()` and `whisper-tiny` transcribes
`jfk.wav` in 0.39 s against 0.87 s on the CPU.

CUDA has been exercised only as far as the *absence* of `nvcc` — the probe at
`configure:167-183` errors correctly. Nothing downstream of that has ever run.
Three specific things are unproven, and they fail in this order:

1. **Does it configure?** `enable_language(CUDA)` plus the host-compiler check.
2. **Does it link?** The link line is hand-assembled in `configure:313-321`
   because `transcribe-link.json` does *not* describe ggml-cuda's dependencies
   (they are `PRIVATE` to that target, so the manifest never sees them). Vulkan
   and Metal are special-cased upstream in `cmake/transcribe-install.cmake:131-139`;
   CUDA is not. That fixup is the single most likely thing to be wrong.
3. **Does it compute?** Device enumeration, `backend = "cuda"`, and output that
   matches the CPU run.

## Prerequisites on the CUDA box

Record all of this before starting — it is the first thing needed to debug
anything below.

```sh
nvidia-smi                       # driver version, GPU name, VRAM
nvcc --version                   # toolkit version
readlink -f "$(command -v nvcc)" # real path -> decides CUDA_LIBDIR (see below)
gcc --version && g++ --version   # host compiler
cmake --version                  # >= 3.18 required by ggml-cuda
R --version
R CMD config CXX
df -h .                          # ~6 GB free for the build tree
nproc && free -g
```

An RTX 3060 is compute capability **8.6**. Any CUDA 11.1+ toolkit covers it;
the practical constraint is the *host compiler*, since `nvcc` refuses GCC
newer than the version its release supports.

## Step 0 — get the code onto that machine

Nothing is pushed yet: the repo has one commit (`initial commit`) and all the
backend work is uncommitted in the working tree. On this machine:

```sh
git switch -c gpu-backends
git add -A
git commit -m "Add opt-in Vulkan/CUDA/Metal backends"
git push -u origin gpu-backends
```

Then on the CUDA box:

```sh
git clone -b gpu-backends https://github.com/JBGruber/rtranscribe.git
cd rtranscribe
```

Note the vendored tree is now 16 MB, so the clone carries `ggml-cuda`'s 184
`.cu` files with it — no separate vendoring step is needed there.

## Step 1 — pre-flight, without R (2 minutes)

Do not start a 30-minute package build to discover a toolkit mismatch. Run the
vendored CMake directly, configure only:

```sh
cmake -S src/transcribe-cpp -B /tmp/cudaprobe \
  -DTRANSCRIBE_CUDA=ON -DTRANSCRIBE_BUILD_TESTS=OFF \
  -DTRANSCRIBE_BUILD_EXAMPLES=OFF -DTRANSCRIBE_INSTALL=ON \
  -DCMAKE_CUDA_ARCHITECTURES=86-real
```

Expected in the output:

```
-- CUDA Toolkit found
-- Using CMAKE_CUDA_ARCHITECTURES=86-real ...
-- Including CUDA backend
-- transcribe install: 0.2.0 shared=OFF backends: cuda;cpu (link manifest: lib/transcribe-link.json)
```

`backends: cuda;cpu` is the line that matters. If this step fails, jump to the
failure table — nothing further will work.

## Step 2 — build the package

Two things to get right, both of which cost 20+ minutes if missed:

- **`./cleanup` first.** A stale `src/rtranscribe.so` is reused by `make`
  (`AGENTS.md` records this trap) — on a fresh clone it is moot, but it matters
  on every rebuild after.
- **Pin the architecture.** `configure` passes `-DGGML_NATIVE=OFF` for CPU
  portability, which makes ggml fall into its *fat* default arch list
  (`50-virtual;61-virtual;70-virtual;75-virtual;80-virtual;86-real;89-real;90-virtual`,
  more on newer toolkits — `ggml/src/ggml-cuda/CMakeLists.txt:25-56`). That
  compiles 184 `.cu` files for eight architectures when one is wanted.
  `TRANSCRIBE_R_CUDA_ARCHS=86-real` is effectively mandatory.

```sh
mkdir -p /tmp/rt-lib
./cleanup
TRANSCRIBE_R_CUDA=1 \
TRANSCRIBE_R_CUDA_ARCHS=86-real \
TRANSCRIBE_R_JOBS=$(nproc) \
  R CMD INSTALL --library=/tmp/rt-lib . 2>&1 | tee /tmp/install-cuda.log
```

Expect the configure banner to say:

```
*** rtranscribe: CUDA backend ENABLED (nvcc: /usr/local/cuda/bin/nvcc)
*** rtranscribe: the CUDA build has not been tested by the package authors;
```

Rough budget: 10–25 minutes for one architecture on 8+ cores. `nvcc` is
memory-hungry — if the machine has less than ~2 GB of RAM per job, lower
`TRANSCRIBE_R_JOBS` rather than letting the OOM killer pick a victim.

## Step 3 — verify the link, not just the exit code

`R CMD INSTALL` exiting 0 is not evidence the CUDA archive was linked. Check
the actual command:

```sh
grep -- "-o rtranscribe.so" /tmp/install-cuda.log
```

It must contain `libggml-cuda.a` inside the `--start-group` set, and
`-lcudart -lcublas -lcuda` after it (that is the `configure:313-321` fixup).
For comparison, the verified Vulkan line on the AMD box was:

```
... --start-group libtranscribe.a libggml.a libggml-cpu.a libggml-vulkan.a libggml-base.a --end-group \
    -Wl,--exclude-libs,ALL -lstdc++ -lm -lpthread -ldl -lvulkan ...
```

Then confirm the runtime dependencies resolved:

```sh
ldd /tmp/rt-lib/rtranscribe/libs/rtranscribe.so | grep -Ei "cuda|cublas"
```

`libcudart.so.*`, `libcublas.so.*` and `libcuda.so.1` should all appear and
none should say `not found`.

## Step 4 — runtime smoke test

```r
.libPaths(c("/tmp/rt-lib", .libPaths()))
library(rtranscribe)

transcribe_devices()                      # expect an RTX 3060 row, kind "cuda"
transcribe_backend_available("cuda")       # TRUE
```

`transcribe_devices()$memory_total` is a free sanity check on which 3060 this
is — 12 GB desktop or 6 GB laptop.

Then prove it computes, and that it computes the *same thing* as the CPU:

```r
wav <- system.file("extdata/jfk.wav", package = "rtranscribe")
mp  <- transcribe_download_model("whisper-tiny")

for (b in c("cpu", "cuda")) {
  t0  <- Sys.time()
  m   <- transcribe_load_model(mp, backend = b)
  res <- transcribe(wav, m)
  cat(sprintf("%-5s %5.2fs  %s\n", b, as.numeric(Sys.time() - t0, "secs"), res$text))
}
```

Compare the two transcripts by eye rather than with `identical()`: GPU and CPU
kernels differ numerically, so a word may legitimately differ. A *wildly*
different or empty CUDA transcript means a real bug — report it with the model
name and the clip.

Watch `nvidia-smi dmon -s um` in a second terminal during the run. If GPU
utilisation stays at zero, the model may have fallen back to the CPU — printing
`m` shows the backend it actually got (`transcribe_model_info(m)$backend` gives
it directly). Note that `backend = "cuda"` is an assertion and errors rather
than falling back, so a silent fallback is only possible under `"auto"`.

## Step 5 — a workload where the GPU should actually win

`jfk.wav` is 11 seconds; on that scale model loading dominates. Use a real
file and a real model:

```r
mp <- transcribe_download_model("whisper-large-v3-turbo")   # 845 MB
m  <- transcribe_load_model(mp, backend = "cuda")
s  <- transcribe_session(m)
system.time(res <- transcribe_run(s, "some-long-interview.mp3"))
res
```

The result print shows the real-time factor. Record CPU and CUDA numbers for
the same file — that is the number worth putting in the README, and it is the
only thing here that justifies the whole exercise to a user.

## Step 6 — the path users will actually take

This is the question that started all of this, so test it as a user would,
with no clone in sight:

```r
# ~/.Renviron:
#   TRANSCRIBE_R_CUDA=1
#   TRANSCRIBE_R_CUDA_ARCHS=86-real
pak::pak("JBGruber/rtranscribe@gpu-backends")
```

Confirm it picks the variables up. `pak` builds in a background worker that
inherits the environment at *process start*, which is exactly why the README
says to use `~/.Renviron` rather than `Sys.setenv()` — if that turns out to be
wrong in either direction, the README needs the correction.

## Step 7 — the gated test suite

```sh
export RTRANSCRIBE_TEST_MODEL=~/.cache/R/rtranscribe/whisper-tiny-Q8_0.gguf
export RTRANSCRIBE_TEST_STREAM_MODEL=~/.cache/R/rtranscribe/moonshine-streaming-tiny-Q8_0.gguf
R -e 'devtools::load_all(); devtools::test()'
```

Note this runs against a `load_all()` build, so it exercises whatever
`src/rtranscribe.so` currently is — the CUDA one, if Step 2 was the last build.
The suite is backend-agnostic; a failure here is a genuine regression, not a
CUDA quirk. One test skips itself on a CUDA build by design
(`tests/testthat/test-handles.R:33`).

## Step 8 — stretch goals, in value order

1. **Diarization, finally.** It has never been verified end to end because the
   smallest diarization-capable model is over 1 GB — which is precisely the
   constraint a 12 GB GPU removes. Find one with
   `transcribe_models(refresh = TRUE)`, confirm with
   `transcribe_supports(m, "diarization")`, then run with `diarize = TRUE` and
   check `res$speakers` and `res$segments$speaker_id`. This would close the
   oldest open item in `AGENTS.md`.
2. **Ctrl-C during a GPU run.** The interrupt path re-raises after the native
   call unwinds; nothing about it is CUDA-specific, but a long GPU run is the
   easiest way to test it honestly.
3. **Streaming on CUDA** with `moonshine-streaming-tiny` via
   `transcribe_stream_all()`.
4. **`R CMD check`** on the CUDA build, for the same NOTEs as elsewhere.
5. **`gpu_device`** selection, only if that machine has a second GPU.

## Failures worth anticipating

| Symptom | Cause | Fix |
| --- | --- | --- |
| `unsupported GNU version! gcc versions later than N are not supported` | `nvcc` rejects the host compiler. ggml honours `CMAKE_CUDA_HOST_COMPILER` (`ggml/src/ggml-cuda/CMakeLists.txt:219-220`) but `configure` has no knob for it | Add one — in the CUDA block of `configure`, `CUDA_EXTRA="$CUDA_EXTRA -DCMAKE_CUDA_HOST_COMPILER=${TRANSCRIBE_R_CUDA_HOST_CC}"` when that variable is set — then build with `TRANSCRIBE_R_CUDA_HOST_CC=/usr/bin/g++-13`. Land the knob afterwards |
| `undefined reference to cudaMalloc` / `cublasSgemm` at the final link | The `configure:313-321` fixup did not find the libraries | Check what `CUDA_ROOT` resolved to: `configure:192` takes `dirname(dirname($NVCC))`, which is right for `/usr/local/cuda/bin/nvcc` and wrong if `nvcc` is a symlink into `/etc/alternatives`. Workaround: `CUDACXX=/usr/local/cuda/bin/nvcc`. Fix: `readlink -f` in `configure` |
| Build runs for an hour | `TRANSCRIBE_R_CUDA_ARCHS` was not set, so the fat arch list is in play | Set `86-real`. Consider making `configure` default to `native` when CUDA is on, since a CUDA build is inherently machine-specific |
| Compiler killed / machine swaps | `nvcc` memory use × `TRANSCRIBE_R_JOBS` | Lower the job count |
| `transcribe_devices()` shows no CUDA row | Driver/runtime mismatch, or the archive was not linked | `nvidia-smi` first, then Step 3's `ldd` check |
| `backend = "cuda"` errors with "No cuda device is available" | Same as above; the R-level check fires before loading | The error text already distinguishes the two causes (`R/model.R:44-51`) |
| Output is empty or garbled on CUDA only | A real upstream bug | Capture model, clip, toolkit version and `transcribe_set_verbosity("debug")` output; this belongs upstream at handy-computer/transcribe.cpp |

## What to send back

- `/tmp/install-cuda.log` (or just the `-o rtranscribe.so` line plus any error)
- the Step 1 CMake output
- the `ldd` output from Step 3
- the R console from Steps 4–5, including `transcribe_devices()` and both timings
- the versions collected in Prerequisites

## What lands after a green run

Small and mechanical, all of it currently phrased as "untested":

- `configure:198-199` — drop the two "has not been tested by the package
  authors" lines for CUDA.
- `README.md` — replace "only Vulkan has been tested here" with the CUDA
  numbers from Step 5, and document `TRANSCRIBE_R_CUDA_ARCHS` as a build-time
  necessity rather than a footnote.
- `AGENTS.md` — the "Verified: CPU and Vulkan" line in the GPU backends
  section, and the CPU/GPU bullet under State and limitations.
- `NEWS.md` — "Only the CPU and Vulkan builds have been tested".
- Whichever contingency knobs Step 2 actually needed (`readlink -f`,
  `TRANSCRIBE_R_CUDA_HOST_CC`, a `native` arch default).
- If diarization worked: retire that limitation everywhere it is recorded, and
  add a test guarded by a new `RTRANSCRIBE_TEST_DIARIZE_MODEL` env var.

No CI change: GitHub's standard runners have neither a CUDA toolkit nor a GPU,
so the `vulkan-build` job stays the only compiled-backend job. CUDA remains
verified by hand, on that machine, at each upstream re-vendor.
