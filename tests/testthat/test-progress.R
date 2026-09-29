# The run-time status display. The offline half covers the helpers that decide
# whether a heartbeat is wanted and what it prints; the gated half proves the
# native abort callback actually calls back into R.

test_that("durations are formatted at a sensible scale", {
  expect_equal(format_duration(11), "11.0 sec")
  expect_equal(format_duration(300), "5.0 min")
  expect_equal(format_duration(7200), "2.0 hr")
  expect_equal(format_duration(NA_real_), "audio")
  expect_equal(format_duration(numeric(0)), "audio")
})

test_that("elapsed time is formatted compactly", {
  expect_equal(format_elapsed(0), "0s")
  expect_equal(format_elapsed(59.9), "59s")
  expect_equal(format_elapsed(723), "12m 3s")
  expect_equal(format_elapsed(3900), "1h 5m")
  expect_equal(format_elapsed(-1), "0s")
})

test_that("the tick interval falls back when the option is nonsense", {
  withr::local_options(list(rtranscribe.tick_interval = NULL))
  expect_equal(tick_interval(), 0.1)

  withr::local_options(list(rtranscribe.tick_interval = 0.25))
  expect_equal(tick_interval(), 0.25)

  for (bad in list(-1, "x", c(1, 2), NA_real_, Inf)) {
    withr::local_options(list(rtranscribe.tick_interval = bad))
    expect_equal(tick_interval(), 0.1)
  }
})

test_that("no heartbeat is built when neither progress nor verbose is on", {
  expect_null(maybe_ticker(FALSE, FALSE, 10))
  expect_null(maybe_ticker(FALSE, NULL, 10))
})

test_that("progress defaults to off outside an interactive session", {
  # maybe_ticker() resolves NULL itself, and testthat runs non-interactively.
  withr::local_options(list(knitr.in.progress = NULL))
  expect_null(maybe_ticker(NULL, FALSE, 10))

  # ...and stays off inside knitr even when interactive.
  withr::local_options(list(knitr.in.progress = TRUE))
  expect_null(maybe_ticker(NULL, FALSE, 10))
})

test_that("verbose alone ticks without drawing a spinner", {
  drained <- 0L
  local_mocked_bindings(flush_native_log = function() drained <<- drained + 1L)

  tick <- maybe_ticker(FALSE, TRUE, 120)
  expect_true(is.function(tick))

  # No progress bar means no cli output at all, but the log is still drained.
  expect_silent(tick())
  expect_equal(drained, 1L)
})

test_that("the tick never propagates an error into the running native call", {
  # It is called re-entrantly from C with the library's frames live, so an
  # error escaping would unwind through them. run_ticker() must swallow.
  local_mocked_bindings(flush_native_log = function() stop("boom"))

  tick <- maybe_ticker(FALSE, TRUE, 120)
  expect_silent(tick())
  expect_no_error(tick())
})

test_that("the spinner format resolves only against cli's own pronouns", {
  # Regression: the duration used to be interpolated as `{dur}`, which cli
  # evaluates in `.envir` -- the caller's frame -- where it does not exist, so
  # every redraw failed and the bar silently never painted.
  fmt <- ticker_format("Transcribing", 2534)

  expect_match(fmt, "42.2 min", fixed = TRUE)
  # The only remaining fields must be cli's, which resolve in any frame.
  fields <- regmatches(fmt, gregexpr("\\{[^}]*\\}", fmt))[[1]]
  expect_true(all(startsWith(fields, "{cli::pb_")))
})

test_that("the status line is drawn before the run, not on the first tick", {
  # Nothing polls until the model's first decode step, which for encoder +
  # one-graph-prefill families is many minutes into a long run. Non-dynamic
  # output turns each render into a plain line capture_messages() can see.
  withr::local_options(list(cli.dynamic = FALSE))

  owner <- function() capture_messages(run_ticker(2534, envir = environment()))
  drawn <- NULL
  capture_messages(drawn <- owner()) # the line cli prints as the bar closes

  expect_length(drawn, 1L)
  expect_match(
    drawn,
    paste("Transcribing 42.2 min of audio |", ticker_waiting),
    fixed = TRUE
  )
})

test_that("a spinner built in one frame redraws when ticked from another", {
  # The tick is called re-entrantly from C, not from the frame that owns the
  # bar, so the two must not be coupled. cli redraws an unforced update only
  # when its own timer is due; when it does not, the line it prints as the bar
  # closes carries the status instead, and when it does, that closing line is
  # just an erase. With `cli.ansi` on, every line is wrapped in `\r...\033[K`
  # even when not dynamic. Stripped of those, the last non-empty line is the
  # one the tick left either way.
  withr::local_options(list(cli.dynamic = FALSE))

  owner <- function() {
    tick <- run_ticker(2534, envir = environment())
    elsewhere <- function() tick()
    elsewhere()
  }
  out <- trimws(cli::ansi_strip(capture_messages(owner())))
  out <- out[nzchar(out)]
  closed <- out[length(out)]

  expect_match(closed, "42\\.2 min of audio \\| [0-9]+s elapsed")
  expect_no_match(closed, ticker_waiting, fixed = TRUE)
})

test_that("the native run calls the heartbeat back into R", {
  path <- skip_without_model()
  pcm <- sample_audio()

  s <- transcribe_session(transcribe_load_model(path))

  n <- 0L
  stamps <- numeric(0)
  tick <- function() {
    n <<- n + 1L
    stamps <<- c(stamps, as.numeric(Sys.time()))
    invisible(NULL)
  }

  raw <- cpp_run(session_ptr(s), pcm, build_run_opts(), TRUE, tick, 0.1)

  expect_gt(n, 0L)
  expect_equal(raw$status, 0L)
  # The C layer throttles to the requested interval; allow for clock slop.
  if (n > 1L) expect_gte(min(diff(stamps)), 0.09)
})

test_that("a heartbeat that always errors cannot break the run", {
  path <- skip_without_model()
  pcm <- sample_audio()

  s <- transcribe_session(transcribe_load_model(path))

  clean <- cpp_run(session_ptr(s), pcm, build_run_opts(), TRUE, NULL, 0.1)
  noisy <- cpp_run(
    session_ptr(s),
    pcm,
    build_run_opts(),
    TRUE,
    function() stop("tick blew up"),
    0.1
  )

  expect_equal(noisy$status, 0L)
  expect_equal(noisy$text, clean$text)
})

test_that("progress and verbose leave the transcript and verbosity untouched", {
  path <- skip_without_model()
  pcm <- sample_audio()

  s <- transcribe_session(transcribe_load_model(path))
  before <- the$verbosity

  plain <- transcribe_run(s, pcm, progress = FALSE)
  spun <- transcribe_run(s, pcm, progress = TRUE)
  loud <- transcribe_run(s, pcm, progress = FALSE, verbose = TRUE)

  expect_equal(spun$text, plain$text)
  expect_equal(loud$text, plain$text)
  expect_equal(the$verbosity, before)
})
