# The handle layer is tagged so that passing the wrong kind of external pointer
# is an R error rather than a wild pointer dereference.

test_that("handle accessors reject non-handles", {
  expect_error(rtranscribe:::cpp_model_info(1L), "model handle")
  expect_error(rtranscribe:::cpp_session_limits("nope"), "session handle")
  expect_error(rtranscribe:::cpp_model_info(NULL), "model handle")
})

test_that("a session handle is not accepted where a model is expected", {
  # An external pointer with the wrong tag must be refused.
  ptr <- methods::new("externalptr")
  expect_error(rtranscribe:::cpp_model_info(ptr), "model handle")
})

test_that("model helpers reject non-model objects", {
  expect_error(transcribe_capabilities("model.gguf"), "transcribe_model")
  expect_error(transcribe_supports(list(), "pnc"), "transcribe_model")
})

test_that("loading a missing model file fails before touching the native layer", {
  expect_error(transcribe_load_model("definitely-not-here.gguf"), "not found")
  expect_error(transcribe("audio.wav", "definitely-not-here.gguf"), "not found")
})

test_that("session helpers reject non-sessions", {
  expect_error(transcribe_session_limits(list()), "transcribe_session")
  expect_error(transcribe_stream_begin(list()), "transcribe_session")
  expect_error(transcribe_stream_feed(list(), numeric(10)), "transcribe_stream")
})

test_that("unsupported backends are reported before loading", {
  skip_if(transcribe_backend_available("cuda"), "CUDA build")
  tmp <- dummy_gguf()
  on.exit(unlink(tmp))
  expect_error(transcribe_load_model(tmp, backend = "cuda"), "device is available")
})
