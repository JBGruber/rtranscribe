# rtranscribe 0.1.0

First release: R bindings to
[transcribe.cpp](https://github.com/handy-computer/transcribe.cpp), built from
bundled sources with no external library to install.

## Transcription

* `transcribe()` transcribes an audio file or PCM vector in one call.
* `transcribe_load_model()`, `transcribe_session()` and `transcribe_run()`
  expose the reusable path, so a model is loaded once and used many times.
* `transcribe_run_batch()` runs several clips in one dispatch, with
  per-utterance statuses.
* Results carry `text`, `raw_text`, detected `language`, and `segments`,
  `words`, `tokens` and `speakers` tibbles, plus stage `timings`.
  `print()`, `format()`, `as.character()` and `as.data.frame()` methods are
  provided.

## Streaming

* `transcribe_stream_begin()` / `_feed()` / `_finalize()` / `_reset()` drive
  incremental transcription, with `transcribe_stream_text()` exposing the
  append-only `committed` view alongside the volatile `full` hypothesis.
* `transcribe_stream_all()` runs the whole loop over one vector.

## Models

* `transcribe_download_model()` and `transcribe_models()` fetch and list a
  small curated registry; any GGUF converted for transcribe.cpp also works.
* `transcribe_capabilities()`, `transcribe_supports()` and
  `transcribe_model_info()` report what a loaded model can do.

## Model-specific options

* `whisper_options()` for Whisper decoding (initial prompt, temperature
  fallback, no-speech gate, seed).
* `parakeet_stream_options()`, `parakeet_buffered_stream_options()`,
  `moonshine_streaming_options()` and `voxtral_realtime_options()` for
  streaming knobs, validated with `transcribe_accepts_options()`.

## Backends

* The default build is CPU-only and needs nothing but a compiler and `cmake`.
* Vulkan, CUDA and Metal can be compiled in per install, from a source install
  (`pak::pak()`, `remotes::install_github()` or `R CMD INSTALL`):

  ```sh
  TRANSCRIBE_R_VULKAN=1 R CMD INSTALL .   # AMD / Intel / NVIDIA, needs glslc
                                          # and the Vulkan + SPIR-V headers
  TRANSCRIBE_R_CUDA=1   R CMD INSTALL .   # NVIDIA, needs the CUDA toolkit
  TRANSCRIBE_R_METAL=1  R CMD INSTALL .   # Apple Silicon
  ```

  `configure` checks for the build dependencies first and fails with an
  install hint rather than deep inside CMake. `transcribe_devices()` then lists
  the GPU alongside the CPU, and `transcribe_load_model(backend = "vulkan")`
  selects it; `backend = "auto"` prefers a GPU and falls back to the CPU.

## Other

* Long runs can be interrupted with Ctrl-C.
* Native diagnostics are buffered off-thread and re-emitted through `cli`;
  control them with `transcribe_set_verbosity()`.
* `transcribe_read_audio()` decodes any `ffmpeg`-readable format to 16 kHz
  mono via the `av` package. It filters out av's spurious "Insufficient memory
  to recode all samples" output, which av prints once per decoded frame
  whenever the target rate is below the file's native rate (that is, on almost
  every real input). The message is a false positive -- av compares the output
  sample count against the input count, which downsampling always reduces --
  and no audio is lost. See [ropensci/av#27](https://github.com/ropensci/av/issues/27).
  Genuine decoder messages are still passed through.

## Known limitations

* Windows is not supported yet (`OS_type: unix`). `configure.win` is in the
  tree as a starting point but is unproven.
* Only the CPU and Vulkan builds have been tested. The CUDA and Metal switches
  are wired up but have not been run on hardware; reports welcome.
* GPU backends require a source install. Prebuilt r-universe binaries are
  CPU-only, since a binary has to install on machines with no GPU SDK.
* Speaker diarization is implemented but has not been verified end-to-end,
  because the smallest diarization-capable model is over 1 GB.
