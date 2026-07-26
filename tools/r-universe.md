# Publishing rtranscribe on r-universe

r-universe builds from a *registry* repository, not from this one. The config
below lives in `<username>.r-universe.dev/packages.json`, not in this package.

## 1. Registry entry

Create (or edit) `https://github.com/JBGruber/JBGruber.r-universe.dev` and add:

```json
[
  {
    "package": "rtranscribe",
    "url": "https://github.com/JBGruber/rtranscribe"
  }
]
```

r-universe picks up `SystemRequirements: cmake (>= 3.16), C++17, GNU make`
from `DESCRIPTION` and installs cmake on its Linux and macOS builders
automatically, so no extra build configuration is needed.

## 2. What gets built

`OS_type: unix` in `DESCRIPTION` means only the Linux and macOS binaries are
produced; the Windows builder will skip the package. Remove that field once
`configure.win` is proven, and r-universe will start building Windows binaries
too.

## 3. Expected R CMD check result

A clean run is `Status: 1 NOTE`:

```
* checking compiled code ... NOTE
File 'rtranscribe/libs/rtranscribe.so':
  Found 'stderr', possibly from 'stderr' (C)
    Objects: 'libggml-base.a', 'libggml-cpu.a', 'libtranscribe.a'
  Found 'stdout', possibly from 'stdout' (C)
    Object: 'libggml-base.a'
```

This comes from the vendored ggml/transcribe.cpp archives, which write to
stderr when no log callback is installed. rtranscribe installs one in
`.onLoad()`, so nothing reaches stderr at run time, but the symbols are still
present in the archives and the check cannot tell the difference. Removing the
NOTE would mean patching upstream, so it is expected and accepted.

Two local gotchas when running the check on a developer machine:

- `--as-cran` (and even the plain dependency step) contacts the configured
  repositories. If `options(repos)` includes a mirror that is slow or
  unreachable, the check stalls at *"checking package dependencies"* with an
  open socket. Point `R_PROFILE_USER` at a profile setting `repos` to a valid
  but empty local repo to make that step resolve instantly.
- The full check recompiles the bundled sources, so budget several minutes.

## 4. Build time

Compiling the bundled transcribe.cpp and ggml sources takes several minutes
(200+ translation units). This is well within r-universe's limits but makes
builds noticeably slower than a pure-R package.

## 5. Installing from r-universe

```r
install.packages("rtranscribe", repos = "https://jbgruber.r-universe.dev")
```

## Re-vendoring the C++ sources

`tools/vendor.sh` refreshes `src/transcribe-cpp/` from an upstream checkout:

```sh
tools/vendor.sh https://github.com/handy-computer/transcribe.cpp v0.2.0
# or from a local clone:
tools/vendor.sh ../transcribe.cpp HEAD
```

It copies only what the CPU build needs, prunes every GPU backend (allowlisting
`ggml-cpu` rather than denylisting known GPU directories, so a new upstream
backend cannot slip in), and records the upstream SHA and ABI hash in
`src/transcribe-cpp/VENDOR`. Commit the result; check `VENDOR` into git so the
pinned revision is auditable.
