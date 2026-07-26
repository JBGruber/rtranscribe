// transcribe_glue.cpp - Rcpp glue over the transcribe.cpp C ABI.
//
// Conventions used throughout:
//
//  * Handles (transcribe_model / transcribe_session) are Rcpp::XPtr with an
//    explicit finalizer; the default `delete` is never used on them.
//  * Every `const char *` the library hands back is BORROWED and dies on the
//    next mutating call, so it is copied at the boundary with
//    Rf_mkCharLenCE(..., CE_UTF8) before it can be invalidated.
//  * Every struct crossing the ABI is initialized by its _init() function
//    before use, otherwise the call is rejected with BAD_STRUCT_SIZE.
//  * Timestamps are int64_t ms on the C side and numeric seconds on the R side.

#include <Rcpp.h>

#include <cmath>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include <transcribe/extensions.h>

using namespace Rcpp;

// ---------------------------------------------------------------------------
// Status handling
// ---------------------------------------------------------------------------

static void stop_if_error(transcribe_status st, const char * what) {
    if (st != TRANSCRIBE_OK) {
        Rcpp::stop("%s failed: %s (status %d)", what, transcribe_status_string((int) st), (int) st);
    }
}

// [[Rcpp::export]]
std::string cpp_status_string(int status) {
    return std::string(transcribe_status_string(status));
}

// ---------------------------------------------------------------------------
// UTF-8 safe string marshalling
// ---------------------------------------------------------------------------

// Copy a borrowed C string into a fresh R CHARSXP tagged UTF-8. A NULL pointer
// becomes NA, which is how "row not present" is distinguished from "empty text".
static SEXP mk_utf8(const char * s) {
    if (s == NULL) return NA_STRING;
    return Rf_mkCharLenCE(s, (int) std::strlen(s), CE_UTF8);
}

// Returns a CharacterVector rather than a bare SEXP on purpose: an unprotected
// SEXP handed to List::create() can be collected while a *later* argument of
// the same call allocates. Rcpp::Vector keeps its own protection.
static Rcpp::CharacterVector mk_utf8_str(const char * s) {
    Rcpp::CharacterVector out(1);
    SET_STRING_ELT(out, 0, mk_utf8(s));
    return out;
}

// ---------------------------------------------------------------------------
// Enum <-> string mapping
// ---------------------------------------------------------------------------

static transcribe_task task_from_string(const std::string & s) {
    if (s == "transcribe") return TRANSCRIBE_TASK_TRANSCRIBE;
    if (s == "translate")  return TRANSCRIBE_TASK_TRANSLATE;
    Rcpp::stop("unknown task '%s' (expected \"transcribe\" or \"translate\")", s.c_str());
}

static transcribe_timestamp_kind timestamps_from_string(const std::string & s) {
    if (s == "none")    return TRANSCRIBE_TIMESTAMPS_NONE;
    if (s == "auto")    return TRANSCRIBE_TIMESTAMPS_AUTO;
    if (s == "segment") return TRANSCRIBE_TIMESTAMPS_SEGMENT;
    if (s == "word")    return TRANSCRIBE_TIMESTAMPS_WORD;
    if (s == "token")   return TRANSCRIBE_TIMESTAMPS_TOKEN;
    Rcpp::stop("unknown timestamps value '%s'", s.c_str());
}

static const char * timestamps_to_string(transcribe_timestamp_kind k) {
    switch (k) {
        case TRANSCRIBE_TIMESTAMPS_NONE:    return "none";
        case TRANSCRIBE_TIMESTAMPS_AUTO:    return "auto";
        case TRANSCRIBE_TIMESTAMPS_SEGMENT: return "segment";
        case TRANSCRIBE_TIMESTAMPS_WORD:    return "word";
        case TRANSCRIBE_TIMESTAMPS_TOKEN:   return "token";
    }
    return "unknown";
}

// The three-state DEFAULT/OFF/ON toggles (pnc, itn, diarize) share one mapping.
static int tristate_from_string(const std::string & s, const char * what) {
    if (s == "default") return 0;
    if (s == "off")     return 1;
    if (s == "on")      return 2;
    Rcpp::stop("unknown %s value '%s' (expected \"default\", \"off\" or \"on\")", what, s.c_str());
}

static transcribe_kv_type kv_type_from_string(const std::string & s) {
    if (s == "auto") return TRANSCRIBE_KV_TYPE_AUTO;
    if (s == "f32")  return TRANSCRIBE_KV_TYPE_F32;
    if (s == "f16")  return TRANSCRIBE_KV_TYPE_F16;
    Rcpp::stop("unknown kv_type '%s' (expected \"auto\", \"f32\" or \"f16\")", s.c_str());
}

static transcribe_backend_request backend_from_string(const std::string & s) {
    if (s == "auto")      return TRANSCRIBE_BACKEND_AUTO;
    if (s == "cpu")       return TRANSCRIBE_BACKEND_CPU;
    if (s == "cpu_accel") return TRANSCRIBE_BACKEND_CPU_ACCEL;
    if (s == "metal")     return TRANSCRIBE_BACKEND_METAL;
    if (s == "vulkan")    return TRANSCRIBE_BACKEND_VULKAN;
    if (s == "cuda")      return TRANSCRIBE_BACKEND_CUDA;
    Rcpp::stop("unknown backend '%s'", s.c_str());
}

static transcribe_feature feature_from_string(const std::string & s) {
    if (s == "initial_prompt")       return TRANSCRIBE_FEATURE_INITIAL_PROMPT;
    if (s == "temperature_fallback") return TRANSCRIBE_FEATURE_TEMPERATURE_FALLBACK;
    if (s == "long_form")            return TRANSCRIBE_FEATURE_LONG_FORM;
    if (s == "cancellation")         return TRANSCRIBE_FEATURE_CANCELLATION;
    if (s == "pnc")                  return TRANSCRIBE_FEATURE_PNC;
    if (s == "itn")                  return TRANSCRIBE_FEATURE_ITN;
    if (s == "diarization")          return TRANSCRIBE_FEATURE_DIARIZATION;
    Rcpp::stop("unknown feature '%s'", s.c_str());
}

static const char * device_type_to_string(transcribe_device_type t) {
    switch (t) {
        case TRANSCRIBE_DEVICE_TYPE_CPU:   return "cpu";
        case TRANSCRIBE_DEVICE_TYPE_GPU:   return "gpu";
        case TRANSCRIBE_DEVICE_TYPE_IGPU:  return "igpu";
        case TRANSCRIBE_DEVICE_TYPE_ACCEL: return "accel";
    }
    return "unknown";
}

static const char * stream_state_to_string(enum transcribe_stream_state s) {
    switch (s) {
        case TRANSCRIBE_STREAM_IDLE:     return "idle";
        case TRANSCRIBE_STREAM_ACTIVE:   return "active";
        case TRANSCRIBE_STREAM_FINISHED: return "finished";
        case TRANSCRIBE_STREAM_FAILED:   return "failed";
    }
    return "unknown";
}

static transcribe_stream_commit_policy commit_policy_from_string(const std::string & s) {
    if (s == "auto")          return TRANSCRIBE_STREAM_COMMIT_AUTO;
    if (s == "on_finalize")   return TRANSCRIBE_STREAM_COMMIT_ON_FINALIZE;
    if (s == "stable_prefix") return TRANSCRIBE_STREAM_COMMIT_STABLE_PREFIX;
    Rcpp::stop("unknown commit_policy '%s'", s.c_str());
}

// ms -> seconds, the unit the R API speaks.
static inline double ms_to_s(int64_t ms) { return (double) ms / 1000.0; }

// ---------------------------------------------------------------------------
// Handles
// ---------------------------------------------------------------------------

// Handles use the raw external-pointer API rather than Rcpp::XPtr so the
// finalizer is explicit (the library's own free function, never `delete`) and
// so borrowed pointers can be handed out with no finalizer at all.
//
// The tag identifies which kind of handle an EXTPTRSXP carries, which turns
// "passed a session where a model was expected" into an R error instead of a
// wild pointer dereference.

static SEXP model_tag() {
    static SEXP tag = Rf_install("rtranscribe_model");
    return tag;
}

static SEXP session_tag() {
    static SEXP tag = Rf_install("rtranscribe_session");
    return tag;
}

static void model_xptr_finalizer(SEXP ext) {
    if (TYPEOF(ext) != EXTPTRSXP) return;
    transcribe_model * p = (transcribe_model *) R_ExternalPtrAddr(ext);
    if (p != NULL) {
        transcribe_model_free(p);
        R_ClearExternalPtr(ext);
    }
}

static void session_xptr_finalizer(SEXP ext) {
    if (TYPEOF(ext) != EXTPTRSXP) return;
    transcribe_session * p = (transcribe_session *) R_ExternalPtrAddr(ext);
    if (p != NULL) {
        transcribe_session_free(p);
        R_ClearExternalPtr(ext);
    }
}

// `prot` is stashed in the external pointer's protection slot, which keeps that
// object reachable for exactly as long as this handle is. It is used for a
// BORROWED model handle taken from a session: the session owns the model and
// frees it on finalization, so the session must not be collected while a model
// handle carved out of it is still alive.
static SEXP make_model_xptr(transcribe_model * m, bool owned, SEXP prot = R_NilValue) {
    SEXP ext = PROTECT(R_MakeExternalPtr((void *) m, model_tag(), prot));
    if (owned) R_RegisterCFinalizerEx(ext, model_xptr_finalizer, TRUE);
    UNPROTECT(1);
    return ext;
}

static SEXP make_session_xptr(transcribe_session * s) {
    SEXP ext = PROTECT(R_MakeExternalPtr((void *) s, session_tag(), R_NilValue));
    R_RegisterCFinalizerEx(ext, session_xptr_finalizer, TRUE);
    UNPROTECT(1);
    return ext;
}

// Dereference with a clear error rather than a segfault when a handle is the
// wrong kind, or was carried across a save/restore of the R session (where the
// address comes back NULL).
static transcribe_model * get_model(SEXP x) {
    if (TYPEOF(x) != EXTPTRSXP || R_ExternalPtrTag(x) != model_tag()) {
        Rcpp::stop("expected a transcribe model handle");
    }
    transcribe_model * m = (transcribe_model *) R_ExternalPtrAddr(x);
    if (m == NULL) {
        Rcpp::stop("invalid model handle (NULL). Model objects cannot be saved and reloaded; "
                   "load the model again in this session.");
    }
    return m;
}

static transcribe_session * get_session(SEXP x) {
    if (TYPEOF(x) != EXTPTRSXP || R_ExternalPtrTag(x) != session_tag()) {
        Rcpp::stop("expected a transcribe session handle");
    }
    transcribe_session * s = (transcribe_session *) R_ExternalPtrAddr(x);
    if (s == NULL) {
        Rcpp::stop("invalid session handle (NULL). Session objects cannot be saved and reloaded; "
                   "create the session again in this session.");
    }
    return s;
}

// ---------------------------------------------------------------------------
// Logging
//
// The log callback may fire on ggml worker threads, so it must never touch R.
// Messages are buffered under a mutex and drained from R after the call
// returns.
// ---------------------------------------------------------------------------

namespace {

struct LogBuffer {
    std::mutex               mu;
    std::vector<std::string> messages;
    std::vector<int>         levels;
    // Severity rank threshold, not a raw transcribe_log_level: the enum's
    // numeric order (INFO 1, WARN 2, ERROR 3, DEBUG 4) is not a severity
    // order, so comparing raw values would drop errors before warnings.
    int    max_rank = 1;  // warn and above
    bool   enabled  = false;
    size_t max_kept = 1000;
};

// 0 = most severe. CONT is a continuation fragment and always passes.
int severity_rank(transcribe_log_level level) {
    switch (level) {
        case TRANSCRIBE_LOG_LEVEL_ERROR: return 0;
        case TRANSCRIBE_LOG_LEVEL_WARN:  return 1;
        case TRANSCRIBE_LOG_LEVEL_INFO:  return 2;
        case TRANSCRIBE_LOG_LEVEL_DEBUG: return 3;
        case TRANSCRIBE_LOG_LEVEL_CONT:  return -1;
        case TRANSCRIBE_LOG_LEVEL_NONE:  return 4;
    }
    return 4;
}

LogBuffer & log_buffer() {
    static LogBuffer b;
    return b;
}

void log_trampoline(transcribe_log_level level, const char * msg, void * /*userdata*/) {
    LogBuffer & b = log_buffer();
    std::lock_guard<std::mutex> lock(b.mu);
    if (!b.enabled) return;
    if (severity_rank(level) > b.max_rank) return;
    if (b.messages.size() >= b.max_kept) return;
    b.messages.push_back(msg == NULL ? std::string() : std::string(msg));
    b.levels.push_back((int) level);
}

}  // namespace

// max_rank is a severity rank: 0 = errors only, 1 = +warnings, 2 = +info,
// 3 = +debug. Anything negative silences the sink.
// [[Rcpp::export]]
void cpp_log_set(bool enabled, int max_rank) {
    LogBuffer & b = log_buffer();
    {
        std::lock_guard<std::mutex> lock(b.mu);
        b.enabled  = enabled;
        b.max_rank = max_rank;
        b.messages.clear();
        b.levels.clear();
    }
    transcribe_log_set(log_trampoline, NULL);
}

// [[Rcpp::export]]
List cpp_log_drain() {
    LogBuffer & b = log_buffer();
    std::vector<std::string> msgs;
    std::vector<int>         lvls;
    {
        std::lock_guard<std::mutex> lock(b.mu);
        msgs.swap(b.messages);
        lvls.swap(b.levels);
    }
    CharacterVector out(msgs.size());
    for (size_t i = 0; i < msgs.size(); ++i) {
        SET_STRING_ELT(out, i, Rf_mkCharLenCE(msgs[i].c_str(), (int) msgs[i].size(), CE_UTF8));
    }
    return List::create(_["message"] = out, _["level"] = wrap(lvls));
}

// ---------------------------------------------------------------------------
// Cancellation (Ctrl-C)
//
// R_CheckUserInterrupt long-jumps when an interrupt is pending, which must
// never happen from inside C++ with live destructors. R_ToplevelExec runs the
// check in a context where the jump is caught, so the abort callback can
// report "interrupt pending" as a plain bool.
// ---------------------------------------------------------------------------

static void check_interrupt_fn(void * /*dummy*/) { R_CheckUserInterrupt(); }

static bool interrupt_pending() { return R_ToplevelExec(check_interrupt_fn, NULL) == FALSE; }

// R_ToplevelExec CONSUMES the pending interrupt when it catches the long jump,
// so by the time the run returns there is nothing left for a later
// checkUserInterrupt() to see. Record the fact here and re-raise it explicitly
// once the native call has unwound and it is safe to throw.
static bool g_interrupted = false;

static bool abort_callback(void * /*user_data*/) {
    if (interrupt_pending()) {
        g_interrupted = true;
        return true;
    }
    return false;
}

// Install the abort hook for the duration of one native call, and make sure it
// is removed again even if marshalling below throws.
namespace {
struct AbortGuard {
    transcribe_session * s;
    bool                 active;

    AbortGuard(transcribe_session * session, bool enable) : s(session), active(enable) {
        if (active) {
            g_interrupted = false;
            transcribe_set_abort_callback(s, abort_callback, NULL);
        }
    }
    ~AbortGuard() {
        if (active) transcribe_set_abort_callback(s, NULL, NULL);
    }
};
}  // namespace

// Turn a caller-triggered abort back into a normal R interrupt.
static void rethrow_if_interrupted(transcribe_status st) {
    if (st == TRANSCRIBE_ERR_ABORTED && g_interrupted) {
        g_interrupted = false;
        Rcpp::stop("interrupted by user");
    }
}

// ---------------------------------------------------------------------------
// Params construction
// ---------------------------------------------------------------------------

// Family extension storage. Only one member is ever live per call; the holder
// keeps it alive for the duration of the run/begin call, which is all the
// library requires (it copies what it needs before returning).
struct ExtHolder {
    transcribe_whisper_run_ext                     whisper;
    transcribe_parakeet_stream_ext                 parakeet;
    transcribe_parakeet_buffered_stream_ext        parakeet_buffered;
    transcribe_moonshine_streaming_stream_ext      moonshine;
    transcribe_voxtral_realtime_stream_ext         voxtral;
    std::string                                    initial_prompt;
    std::vector<int32_t>                           prompt_tokens;
    const transcribe_ext *                         ptr = NULL;
};

static double opt_num(const List & l, const char * name, double fallback) {
    if (!l.containsElementNamed(name)) return fallback;
    SEXP v = l[name];
    if (Rf_isNull(v) || Rf_length(v) == 0) return fallback;
    double d = Rcpp::as<double>(v);
    if (ISNA(d)) return fallback;
    return d;
}

static bool opt_bool(const List & l, const char * name, bool fallback) {
    if (!l.containsElementNamed(name)) return fallback;
    SEXP v = l[name];
    if (Rf_isNull(v) || Rf_length(v) == 0) return fallback;
    return Rcpp::as<bool>(v);
}

// Build the typed family extension named by opts$kind.
static void build_ext(const List & opts, ExtHolder & h) {
    std::string kind = Rcpp::as<std::string>(opts["kind"]);

    if (kind == "whisper_run") {
        transcribe_whisper_run_ext_init(&h.whisper);
        if (opts.containsElementNamed("initial_prompt") && !Rf_isNull(opts["initial_prompt"])) {
            h.initial_prompt      = Rcpp::as<std::string>(opts["initial_prompt"]);
            h.whisper.initial_prompt = h.initial_prompt.c_str();
        }
        if (opts.containsElementNamed("prompt_tokens") && !Rf_isNull(opts["prompt_tokens"])) {
            IntegerVector pt = opts["prompt_tokens"];
            h.prompt_tokens.assign(pt.begin(), pt.end());
            if (!h.prompt_tokens.empty()) {
                h.whisper.prompt_tokens   = h.prompt_tokens.data();
                h.whisper.n_prompt_tokens = h.prompt_tokens.size();
            }
        }
        if (opts.containsElementNamed("prompt_condition") && !Rf_isNull(opts["prompt_condition"])) {
            std::string pc = Rcpp::as<std::string>(opts["prompt_condition"]);
            if (pc == "first_segment") {
                h.whisper.prompt_condition = TRANSCRIBE_WHISPER_PROMPT_FIRST_SEGMENT;
            } else if (pc == "all_segments") {
                h.whisper.prompt_condition = TRANSCRIBE_WHISPER_PROMPT_ALL_SEGMENTS;
            } else {
                Rcpp::stop("unknown prompt_condition '%s'", pc.c_str());
            }
        }
        h.whisper.condition_on_prev_tokens =
            opt_bool(opts, "condition_on_prev_tokens", h.whisper.condition_on_prev_tokens);
        h.whisper.max_prev_context_tokens =
            (int32_t) opt_num(opts, "max_prev_context_tokens", h.whisper.max_prev_context_tokens);
        h.whisper.temperature     = (float) opt_num(opts, "temperature", h.whisper.temperature);
        h.whisper.temperature_inc = (float) opt_num(opts, "temperature_inc", h.whisper.temperature_inc);
        h.whisper.compression_ratio_thold =
            (float) opt_num(opts, "compression_ratio_thold", h.whisper.compression_ratio_thold);
        h.whisper.logprob_thold   = (float) opt_num(opts, "logprob_thold", h.whisper.logprob_thold);
        h.whisper.no_speech_thold = (float) opt_num(opts, "no_speech_thold", h.whisper.no_speech_thold);
        h.whisper.seed            = (uint32_t) opt_num(opts, "seed", h.whisper.seed);
        h.whisper.max_initial_timestamp =
            (float) opt_num(opts, "max_initial_timestamp", h.whisper.max_initial_timestamp);
        h.ptr = &h.whisper.ext;

    } else if (kind == "parakeet_stream") {
        transcribe_parakeet_stream_ext_init(&h.parakeet);
        h.parakeet.att_context_right =
            (int32_t) opt_num(opts, "att_context_right", h.parakeet.att_context_right);
        h.ptr = &h.parakeet.ext;

    } else if (kind == "parakeet_buffered_stream") {
        transcribe_parakeet_buffered_stream_ext_init(&h.parakeet_buffered);
        h.parakeet_buffered.left_ms  = (int32_t) opt_num(opts, "left_ms", h.parakeet_buffered.left_ms);
        h.parakeet_buffered.chunk_ms = (int32_t) opt_num(opts, "chunk_ms", h.parakeet_buffered.chunk_ms);
        h.parakeet_buffered.right_ms = (int32_t) opt_num(opts, "right_ms", h.parakeet_buffered.right_ms);
        h.ptr = &h.parakeet_buffered.ext;

    } else if (kind == "moonshine_streaming") {
        transcribe_moonshine_streaming_stream_ext_init(&h.moonshine);
        h.moonshine.min_decode_interval_ms =
            (int32_t) opt_num(opts, "min_decode_interval_ms", h.moonshine.min_decode_interval_ms);
        h.ptr = &h.moonshine.ext;

    } else if (kind == "voxtral_realtime") {
        transcribe_voxtral_realtime_stream_ext_init(&h.voxtral);
        h.voxtral.num_delay_tokens =
            (int32_t) opt_num(opts, "num_delay_tokens", h.voxtral.num_delay_tokens);
        h.voxtral.min_decode_interval_ms =
            (int32_t) opt_num(opts, "min_decode_interval_ms", h.voxtral.min_decode_interval_ms);
        h.ptr = &h.voxtral.ext;

    } else {
        Rcpp::stop("unknown family option kind '%s'", kind.c_str());
    }
}

// Holds the run params plus the storage its char* fields point into.
struct RunParamsHolder {
    transcribe_run_params p;
    std::string           language;
    std::string           target_language;
    ExtHolder             ext;
};

static void build_run_params(const List & opts, RunParamsHolder & h) {
    transcribe_run_params_init(&h.p);

    if (opts.containsElementNamed("task") && !Rf_isNull(opts["task"])) {
        h.p.task = task_from_string(Rcpp::as<std::string>(opts["task"]));
    }
    if (opts.containsElementNamed("timestamps") && !Rf_isNull(opts["timestamps"])) {
        h.p.timestamps = timestamps_from_string(Rcpp::as<std::string>(opts["timestamps"]));
    }
    if (opts.containsElementNamed("pnc") && !Rf_isNull(opts["pnc"])) {
        h.p.pnc = (enum transcribe_pnc_mode) tristate_from_string(Rcpp::as<std::string>(opts["pnc"]), "pnc");
    }
    if (opts.containsElementNamed("itn") && !Rf_isNull(opts["itn"])) {
        h.p.itn = (enum transcribe_itn_mode) tristate_from_string(Rcpp::as<std::string>(opts["itn"]), "itn");
    }
    if (opts.containsElementNamed("diarize") && !Rf_isNull(opts["diarize"])) {
        h.p.diarize =
            (enum transcribe_diarize_mode) tristate_from_string(Rcpp::as<std::string>(opts["diarize"]), "diarize");
    }
    if (opts.containsElementNamed("language") && !Rf_isNull(opts["language"])) {
        h.language  = Rcpp::as<std::string>(opts["language"]);
        h.p.language = h.language.c_str();
    }
    if (opts.containsElementNamed("target_language") && !Rf_isNull(opts["target_language"])) {
        h.target_language      = Rcpp::as<std::string>(opts["target_language"]);
        h.p.target_language    = h.target_language.c_str();
    }
    h.p.keep_special_tags = opt_bool(opts, "keep_special_tags", h.p.keep_special_tags);
    h.p.spec_k_drafts     = (int32_t) opt_num(opts, "spec_k_drafts", h.p.spec_k_drafts);

    if (opts.containsElementNamed("family") && !Rf_isNull(opts["family"])) {
        build_ext(List(opts["family"]), h.ext);
        h.p.family = h.ext.ptr;
    }
}

// ---------------------------------------------------------------------------
// Version / init / devices
// ---------------------------------------------------------------------------

// [[Rcpp::export]]
List cpp_version() {
    return List::create(_["version"] = mk_utf8_str(transcribe_version()),
                        _["commit"]  = mk_utf8_str(transcribe_version_commit()));
}

// [[Rcpp::export]]
int cpp_init_backends_default() { return (int) transcribe_init_backends_default(); }

// [[Rcpp::export]]
int cpp_init_backends(std::string dir) { return (int) transcribe_init_backends(dir.c_str()); }

// [[Rcpp::export]]
bool cpp_backend_available(std::string kind) {
    return transcribe_backend_available(backend_from_string(kind));
}

static List device_to_list(const transcribe_backend_device & d) {
    return List::create(_["name"]         = mk_utf8_str(d.name),
                        _["description"]  = mk_utf8_str(d.description),
                        _["kind"]         = mk_utf8_str(d.kind),
                        _["device_id"]    = d.device_id == NULL ? CharacterVector::create(NA_STRING)
                                                                : mk_utf8_str(d.device_id),
                        _["device_type"]  = std::string(device_type_to_string(d.device_type)),
                        _["memory_total"] = (double) d.memory_total,
                        _["memory_free"]  = (double) d.memory_free);
}

// [[Rcpp::export]]
List cpp_devices() {
    int n = transcribe_backend_device_count();
    List out(n);
    for (int i = 0; i < n; ++i) {
        transcribe_backend_device d;
        transcribe_backend_device_init(&d);
        stop_if_error(transcribe_get_backend_device(i, &d), "transcribe_get_backend_device");
        out[i] = device_to_list(d);
    }
    return out;
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

// [[Rcpp::export]]
SEXP cpp_model_load(std::string path, std::string backend, int gpu_device) {
    transcribe_model_load_params lp;
    transcribe_model_load_params_init(&lp);
    lp.backend    = backend_from_string(backend);
    lp.gpu_device = gpu_device;

    transcribe_model * m = NULL;
    stop_if_error(transcribe_model_load_file(path.c_str(), &lp, &m), "loading model");
    if (m == NULL) Rcpp::stop("model load returned OK but produced no model");

    return make_model_xptr(m, /*owned=*/true);
}

// [[Rcpp::export]]
List cpp_model_capabilities(SEXP model) {
    transcribe_model * m = get_model(model);

    transcribe_capabilities c;
    transcribe_capabilities_init(&c);
    stop_if_error(transcribe_model_get_capabilities(m, &c), "reading capabilities");

    CharacterVector langs(c.n_languages);
    for (int i = 0; i < c.n_languages; ++i) {
        SET_STRING_ELT(langs, i, mk_utf8(c.languages[i]));
    }
    CharacterVector tlangs(c.n_translate_target_languages);
    for (int i = 0; i < c.n_translate_target_languages; ++i) {
        SET_STRING_ELT(tlangs, i, mk_utf8(c.translate_target_languages[i]));
    }

    return List::create(
        _["native_sample_rate"]        = (int) c.native_sample_rate,
        _["languages"]                 = langs,
        _["max_timestamp_kind"]        = std::string(timestamps_to_string(c.max_timestamp_kind)),
        _["supports_language_detect"]  = (bool) c.supports_language_detect,
        _["supports_translate"]        = (bool) c.supports_translate,
        _["supports_streaming"]        = (bool) c.supports_streaming,
        _["supports_spec_decode"]      = (bool) c.supports_spec_decode,
        _["max_audio_ms"]              = (double) c.max_audio_ms,
        _["translate_target_languages"] = tlangs);
}

// [[Rcpp::export]]
bool cpp_model_supports(SEXP model, std::string feature) {
    return transcribe_model_supports(get_model(model), feature_from_string(feature));
}

// [[Rcpp::export]]
List cpp_model_info(SEXP model) {
    transcribe_model * m = get_model(model);
    return List::create(_["arch"]    = mk_utf8_str(transcribe_model_arch_string(m)),
                        _["variant"] = mk_utf8_str(transcribe_model_variant_string(m)),
                        _["backend"] = mk_utf8_str(transcribe_model_backend(m)));
}

// [[Rcpp::export]]
SEXP cpp_model_meta(SEXP model, std::string key) {
    return mk_utf8_str(transcribe_model_meta_val_str(get_model(model), key.c_str()));
}

// [[Rcpp::export]]
SEXP cpp_model_device(SEXP model) {
    transcribe_backend_device d;
    transcribe_backend_device_init(&d);
    transcribe_status st = transcribe_model_get_device(get_model(model), &d);
    if (st != TRANSCRIBE_OK) return R_NilValue;
    return device_to_list(d);
}

// [[Rcpp::export]]
bool cpp_model_accepts_ext_kind(SEXP model, std::string slot, std::string kind) {
    transcribe_ext_slot s;
    if (slot == "run")         s = TRANSCRIBE_EXT_SLOT_RUN;
    else if (slot == "stream") s = TRANSCRIBE_EXT_SLOT_STREAM;
    else Rcpp::stop("unknown extension slot '%s'", slot.c_str());

    uint32_t k;
    if (kind == "whisper_run")                   k = TRANSCRIBE_EXT_KIND_WHISPER_RUN;
    else if (kind == "parakeet_stream")          k = TRANSCRIBE_EXT_KIND_PARAKEET_STREAM;
    else if (kind == "parakeet_buffered_stream") k = TRANSCRIBE_EXT_KIND_PARAKEET_BUFFERED_STREAM;
    else if (kind == "moonshine_streaming")      k = TRANSCRIBE_EXT_KIND_MOONSHINE_STREAMING_STREAM;
    else if (kind == "voxtral_realtime")         k = TRANSCRIBE_EXT_KIND_VOXTRAL_REALTIME_STREAM;
    else Rcpp::stop("unknown extension kind '%s'", kind.c_str());

    return transcribe_model_accepts_ext_kind(get_model(model), s, k);
}

// [[Rcpp::export]]
IntegerVector cpp_tokenize(SEXP model, std::string text) {
    transcribe_model * m = get_model(model);

    std::vector<int32_t> buf(text.size() + 16);
    int n = transcribe_tokenize(m, text.c_str(), buf.data(), buf.size());
    if (n == INT_MIN) {
        Rcpp::stop("tokenization is not available for this model's vocabulary");
    }
    if (n < 0) {
        buf.resize(-n);
        n = transcribe_tokenize(m, text.c_str(), buf.data(), buf.size());
        if (n == INT_MIN) Rcpp::stop("tokenization is not available for this model's vocabulary");
        if (n < 0) Rcpp::stop("tokenization failed to size its output buffer");
    }
    return IntegerVector(buf.begin(), buf.begin() + n);
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

// [[Rcpp::export]]
SEXP cpp_session_init(SEXP model, int n_threads, std::string kv_type, int n_ctx) {
    transcribe_model * m = get_model(model);

    transcribe_session_params sp;
    transcribe_session_params_init(&sp);
    sp.n_threads = n_threads;
    sp.kv_type   = kv_type_from_string(kv_type);
    sp.n_ctx     = (int32_t) n_ctx;

    transcribe_session * s = NULL;
    stop_if_error(transcribe_session_init(m, &sp, &s), "creating session");
    if (s == NULL) Rcpp::stop("session init returned OK but produced no session");

    return make_session_xptr(s);
}

// [[Rcpp::export]]
SEXP cpp_open(std::string path, std::string backend, int gpu_device, int n_threads, std::string kv_type, int n_ctx) {
    transcribe_model_load_params lp;
    transcribe_model_load_params_init(&lp);
    lp.backend    = backend_from_string(backend);
    lp.gpu_device = gpu_device;

    transcribe_session_params sp;
    transcribe_session_params_init(&sp);
    sp.n_threads = n_threads;
    sp.kv_type   = kv_type_from_string(kv_type);
    sp.n_ctx     = (int32_t) n_ctx;

    transcribe_session * s = NULL;
    stop_if_error(transcribe_open(path.c_str(), &lp, &sp, &s), "opening model");
    if (s == NULL) Rcpp::stop("transcribe_open returned OK but produced no session");

    return make_session_xptr(s);
}

// [[Rcpp::export]]
List cpp_session_limits(SEXP session) {
    transcribe_session_limits l;
    transcribe_session_limits_init(&l);
    stop_if_error(transcribe_session_get_limits(get_session(session), &l), "reading session limits");
    return List::create(_["effective_n_ctx"]        = (int) l.effective_n_ctx,
                        _["effective_max_audio_ms"] = (double) l.effective_max_audio_ms,
                        _["max_kv_bytes"]           = (double) l.max_kv_bytes);
}

// The model a session was opened against, for capability probes on the
// one-shot transcribe_open path. Borrowed: no finalizer, and the returned
// pointer must not outlive the session.
// [[Rcpp::export]]
SEXP cpp_session_model(SEXP session) {
    const transcribe_model * m = transcribe_get_model(get_session(session));
    if (m == NULL) return R_NilValue;
    // Borrowed, and protected by the session it came from.
    return make_model_xptr(const_cast<transcribe_model *>(m), /*owned=*/false, /*prot=*/session);
}

// ---------------------------------------------------------------------------
// Result marshalling
//
// Every row is copied out immediately: the text pointers alias session storage
// and are invalidated by the next run/stream call.
// ---------------------------------------------------------------------------

// Row readers are parameterised over single-result vs batch-indexed accessors
// so one marshaller serves both.
struct ResultReader {
    const transcribe_session * s;
    int                        utt;    // batch index, or -1 for the single-result accessors
    bool                       batch;

    int n_segments() const { return batch ? transcribe_batch_n_segments(s, utt) : transcribe_n_segments(s); }
    int n_words() const { return batch ? transcribe_batch_n_words(s, utt) : transcribe_n_words(s); }
    int n_tokens() const { return batch ? transcribe_batch_n_tokens(s, utt) : transcribe_n_tokens(s); }
    int n_speakers() const {
        return batch ? transcribe_batch_n_speaker_segments(s, utt) : transcribe_n_speaker_segments(s);
    }
    const char * full_text() const { return batch ? transcribe_batch_full_text(s, utt) : transcribe_full_text(s); }
    const char * raw_text() const { return batch ? transcribe_batch_raw_text(s, utt) : transcribe_raw_text(s); }
    const char * language() const {
        return batch ? transcribe_batch_detected_language(s, utt) : transcribe_detected_language(s);
    }
    transcribe_timestamp_kind ts_kind() const {
        return batch ? transcribe_batch_returned_timestamp_kind(s, utt) : transcribe_returned_timestamp_kind(s);
    }
    transcribe_status get_segment(int j, transcribe_segment * o) const {
        return batch ? transcribe_batch_get_segment(s, utt, j, o) : transcribe_get_segment(s, j, o);
    }
    transcribe_status get_word(int j, transcribe_word * o) const {
        return batch ? transcribe_batch_get_word(s, utt, j, o) : transcribe_get_word(s, j, o);
    }
    transcribe_status get_token(int j, transcribe_token * o) const {
        return batch ? transcribe_batch_get_token(s, utt, j, o) : transcribe_get_token(s, j, o);
    }
    transcribe_status get_speaker(int j, transcribe_speaker_segment * o) const {
        return batch ? transcribe_batch_get_speaker_segment(s, utt, j, o) : transcribe_get_speaker_segment(s, j, o);
    }
    transcribe_status get_timings(transcribe_timings * o) const {
        return batch ? transcribe_batch_get_timings(s, utt, o) : transcribe_get_timings(s, o);
    }
};

static List segments_df(const ResultReader & r) {
    int n = r.n_segments();
    NumericVector   start(n), end(n);
    CharacterVector text(n);
    IntegerVector   speaker(n), first_word(n), n_words(n), first_token(n), n_tokens(n);

    for (int i = 0; i < n; ++i) {
        transcribe_segment seg;
        transcribe_segment_init(&seg);
        stop_if_error(r.get_segment(i, &seg), "reading segment");
        start[i]       = ms_to_s(seg.t0_ms);
        end[i]         = ms_to_s(seg.t1_ms);
        SET_STRING_ELT(text, i, mk_utf8(seg.text));
        speaker[i]     = seg.speaker_id == 0 ? NA_INTEGER : (int) seg.speaker_id;
        first_word[i]  = seg.first_word;
        n_words[i]     = seg.n_words;
        first_token[i] = seg.first_token;
        n_tokens[i]    = seg.n_tokens;
    }
    return List::create(_["start"] = start, _["end"] = end, _["text"] = text, _["speaker_id"] = speaker,
                        _["first_word"] = first_word, _["n_words"] = n_words, _["first_token"] = first_token,
                        _["n_tokens"] = n_tokens);
}

static List words_df(const ResultReader & r) {
    int n = r.n_words();
    NumericVector   start(n), end(n);
    CharacterVector text(n);
    IntegerVector   seg_index(n), first_token(n), n_tokens(n);

    for (int i = 0; i < n; ++i) {
        transcribe_word w;
        transcribe_word_init(&w);
        stop_if_error(r.get_word(i, &w), "reading word");
        start[i]       = ms_to_s(w.t0_ms);
        end[i]         = ms_to_s(w.t1_ms);
        SET_STRING_ELT(text, i, mk_utf8(w.text));
        seg_index[i]   = w.seg_index + 1;  // 1-based for R
        first_token[i] = w.first_token;
        n_tokens[i]    = w.n_tokens;
    }
    return List::create(_["start"] = start, _["end"] = end, _["text"] = text, _["segment"] = seg_index,
                        _["first_token"] = first_token, _["n_tokens"] = n_tokens);
}

static List tokens_df(const ResultReader & r) {
    int n = r.n_tokens();
    IntegerVector   id(n), seg_index(n), word_index(n);
    NumericVector   p(n), start(n), end(n);
    CharacterVector text(n);

    for (int i = 0; i < n; ++i) {
        transcribe_token t;
        transcribe_token_init(&t);
        stop_if_error(r.get_token(i, &t), "reading token");
        id[i]         = t.id;
        p[i]          = std::isnan(t.p) ? NA_REAL : (double) t.p;
        start[i]      = ms_to_s(t.t0_ms);
        end[i]        = ms_to_s(t.t1_ms);
        SET_STRING_ELT(text, i, mk_utf8(t.text));
        seg_index[i]  = t.seg_index + 1;
        word_index[i] = t.word_index + 1;
    }
    return List::create(_["id"] = id, _["p"] = p, _["start"] = start, _["end"] = end, _["text"] = text,
                        _["segment"] = seg_index, _["word"] = word_index);
}

static List speakers_df(const ResultReader & r) {
    int n = r.n_speakers();
    NumericVector start(n), end(n), p(n);
    IntegerVector speaker(n);

    for (int i = 0; i < n; ++i) {
        transcribe_speaker_segment sp;
        transcribe_speaker_segment_init(&sp);
        stop_if_error(r.get_speaker(i, &sp), "reading speaker segment");
        start[i]   = ms_to_s(sp.t0_ms);
        end[i]     = ms_to_s(sp.t1_ms);
        speaker[i] = sp.speaker_id == 0 ? NA_INTEGER : (int) sp.speaker_id;
        p[i]       = std::isnan(sp.p) ? NA_REAL : (double) sp.p;
    }
    return List::create(_["start"] = start, _["end"] = end, _["speaker_id"] = speaker, _["p"] = p);
}

static List timings_list(const ResultReader & r) {
    transcribe_timings t;
    transcribe_timings_init(&t);
    if (r.get_timings(&t) != TRANSCRIBE_OK) {
        return List::create(_["load"] = NA_REAL, _["mel"] = NA_REAL, _["encode"] = NA_REAL, _["decode"] = NA_REAL);
    }
    return List::create(_["load"]   = (double) t.load_ms / 1000.0,
                        _["mel"]    = (double) t.mel_ms / 1000.0,
                        _["encode"] = (double) t.encode_ms / 1000.0,
                        _["decode"] = (double) t.decode_ms / 1000.0);
}

static List marshal_result(const ResultReader & r, transcribe_status status) {
    return List::create(_["text"]            = mk_utf8_str(r.full_text()),
                        _["raw_text"]        = mk_utf8_str(r.raw_text()),
                        _["language"]        = mk_utf8_str(r.language()),
                        _["timestamp_kind"]  = std::string(timestamps_to_string(r.ts_kind())),
                        _["segments"]        = segments_df(r),
                        _["words"]           = words_df(r),
                        _["tokens"]          = tokens_df(r),
                        _["speakers"]        = speakers_df(r),
                        _["timings"]         = timings_list(r),
                        _["status"]          = (int) status,
                        _["status_message"]  = std::string(transcribe_status_string((int) status)));
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

// Statuses that leave a readable partial transcript on the session rather than
// meaning "nothing happened".
static bool is_partial_status(transcribe_status st) {
    return st == TRANSCRIBE_ERR_ABORTED || st == TRANSCRIBE_ERR_OUTPUT_TRUNCATED;
}

// [[Rcpp::export]]
List cpp_run(SEXP session, NumericVector pcm, List opts, bool interruptible) {
    transcribe_session * s = get_session(session);

    std::vector<float> buf(pcm.size());
    for (R_xlen_t i = 0; i < pcm.size(); ++i) buf[i] = (float) pcm[i];

    RunParamsHolder h;
    build_run_params(opts, h);

    transcribe_status st;
    {
        AbortGuard guard(s, interruptible);
        st = transcribe_run(s, buf.data(), (int) buf.size(), &h.p);
    }
    rethrow_if_interrupted(st);
    if (st != TRANSCRIBE_OK && !is_partial_status(st)) {
        stop_if_error(st, "transcription");
    }

    ResultReader r{s, -1, false};
    List out = marshal_result(r, st);
    out["aborted"]   = (bool) transcribe_was_aborted(s);
    out["truncated"] = (bool) transcribe_was_truncated(s);
    return out;
}

// [[Rcpp::export]]
List cpp_run_batch(SEXP session, List pcms, List opts, bool interruptible) {
    transcribe_session * s = get_session(session);

    int n = pcms.size();
    if (n <= 0) Rcpp::stop("batch must contain at least one audio vector");

    std::vector<std::vector<float>> bufs(n);
    std::vector<const float *>      ptrs(n);
    std::vector<int>                lens(n);
    for (int i = 0; i < n; ++i) {
        NumericVector v = pcms[i];
        bufs[i].resize(v.size());
        for (R_xlen_t j = 0; j < v.size(); ++j) bufs[i][j] = (float) v[j];
        ptrs[i] = bufs[i].data();
        lens[i] = (int) bufs[i].size();
    }

    RunParamsHolder h;
    build_run_params(opts, h);

    transcribe_status st;
    {
        AbortGuard guard(s, interruptible);
        st = transcribe_run_batch(s, ptrs.data(), lens.data(), n, &h.p);
    }
    rethrow_if_interrupted(st);
    if (st != TRANSCRIBE_OK && st != TRANSCRIBE_ERR_ABORTED) stop_if_error(st, "batch transcription");

    int  n_res = transcribe_batch_n_results(s);
    List out(n_res);
    for (int i = 0; i < n_res; ++i) {
        transcribe_status ust = transcribe_batch_status(s, i);
        ResultReader      r{s, i, true};
        out[i] = marshal_result(r, ust);
    }
    return out;
}

// ---------------------------------------------------------------------------
// Streaming
// ---------------------------------------------------------------------------

// [[Rcpp::export]]
void cpp_stream_begin(SEXP session, List run_opts, List stream_opts) {
    transcribe_session * s = get_session(session);

    RunParamsHolder h;
    build_run_params(run_opts, h);

    transcribe_stream_params sp;
    transcribe_stream_params_init(&sp);
    ExtHolder sext;
    if (stream_opts.containsElementNamed("family") && !Rf_isNull(stream_opts["family"])) {
        build_ext(List(stream_opts["family"]), sext);
        sp.family = sext.ptr;
    }
    if (stream_opts.containsElementNamed("commit_policy") && !Rf_isNull(stream_opts["commit_policy"])) {
        sp.commit_policy = commit_policy_from_string(Rcpp::as<std::string>(stream_opts["commit_policy"]));
    }
    sp.stable_prefix_agreement_n =
        (uint32_t) opt_num(stream_opts, "stable_prefix_agreement_n", sp.stable_prefix_agreement_n);

    stop_if_error(transcribe_stream_begin(s, &h.p, &sp), "beginning stream");
}

static List update_to_list(const transcribe_stream_update & u) {
    return List::create(_["result_changed"]    = (bool) u.result_changed,
                        _["is_final"]          = (bool) u.is_final,
                        _["revision"]          = (int) u.revision,
                        _["input_received"]    = ms_to_s(u.input_received_ms),
                        _["audio_committed"]   = ms_to_s(u.audio_committed_ms),
                        _["buffered"]          = ms_to_s(u.buffered_ms),
                        _["committed_changed"] = (bool) u.committed_changed,
                        _["tentative_changed"] = (bool) u.tentative_changed);
}

// [[Rcpp::export]]
List cpp_stream_feed(SEXP session, NumericVector pcm, bool interruptible) {
    transcribe_session * s = get_session(session);

    std::vector<float> buf(pcm.size());
    for (R_xlen_t i = 0; i < pcm.size(); ++i) buf[i] = (float) pcm[i];

    transcribe_stream_update u;
    transcribe_stream_update_init(&u);

    transcribe_status st;
    {
        AbortGuard guard(s, interruptible);
        st = transcribe_stream_feed(s, buf.data(), (int) buf.size(), &u);
    }
    rethrow_if_interrupted(st);
    stop_if_error(st, "feeding stream");
    return update_to_list(u);
}

// [[Rcpp::export]]
List cpp_stream_finalize(SEXP session, bool interruptible) {
    transcribe_session * s = get_session(session);

    transcribe_stream_update u;
    transcribe_stream_update_init(&u);

    transcribe_status st;
    {
        AbortGuard guard(s, interruptible);
        st = transcribe_stream_finalize(s, &u);
    }
    rethrow_if_interrupted(st);
    stop_if_error(st, "finalizing stream");

    List out = update_to_list(u);
    out["truncated"] = (bool) transcribe_was_truncated(s);
    return out;
}

// [[Rcpp::export]]
void cpp_stream_reset(SEXP session) { transcribe_stream_reset(get_session(session)); }

// [[Rcpp::export]]
List cpp_stream_text(SEXP session) {
    transcribe_stream_text t;
    transcribe_stream_text_init(&t);
    stop_if_error(transcribe_stream_get_text(get_session(session), &t), "reading stream text");

    // Byte lengths are authoritative here: the three views are slices of one
    // buffer and are not individually NUL-terminated.
    CharacterVector full(1), comm(1), tent(1);
    SET_STRING_ELT(full, 0,
                   t.full_text == NULL ? NA_STRING
                                       : Rf_mkCharLenCE(t.full_text, (int) t.full_text_bytes, CE_UTF8));
    SET_STRING_ELT(comm, 0,
                   t.committed_text == NULL
                       ? NA_STRING
                       : Rf_mkCharLenCE(t.committed_text, (int) t.committed_text_bytes, CE_UTF8));
    SET_STRING_ELT(tent, 0,
                   t.tentative_text == NULL
                       ? NA_STRING
                       : Rf_mkCharLenCE(t.tentative_text, (int) t.tentative_text_bytes, CE_UTF8));

    return List::create(_["full"] = full, _["committed"] = comm, _["tentative"] = tent);
}

// [[Rcpp::export]]
List cpp_stream_state(SEXP session) {
    transcribe_session * s = get_session(session);
    return List::create(_["state"]             = std::string(stream_state_to_string(transcribe_stream_get_state(s))),
                        _["revision"]          = transcribe_stream_revision(s),
                        _["n_committed_segments"] = transcribe_stream_n_committed_segments(s),
                        _["n_committed_words"]    = transcribe_stream_n_committed_words(s),
                        _["n_committed_tokens"]   = transcribe_stream_n_committed_tokens(s),
                        _["last_status"]       = (int) transcribe_stream_last_status(s),
                        _["aborted"]           = (bool) transcribe_was_aborted(s));
}

// Current raw snapshot of an active or finished stream, in the same shape as a
// one-shot result.
// [[Rcpp::export]]
List cpp_stream_snapshot(SEXP session) {
    transcribe_session * s = get_session(session);
    ResultReader         r{s, -1, false};
    return marshal_result(r, transcribe_stream_last_status(s));
}

// ---------------------------------------------------------------------------
// Whisper decoding traces
// ---------------------------------------------------------------------------

// [[Rcpp::export]]
List cpp_whisper_chunk_traces(SEXP session) {
    transcribe_session * s = get_session(session);
    int                  n = transcribe_get_whisper_chunk_count(s);

    NumericVector start(n), end(n), temperature(n), compression_ratio(n), avg_logprob(n), no_speech_prob(n);
    LogicalVector no_speech_triggered(n);
    IntegerVector n_fallbacks(n);

    for (int i = 0; i < n; ++i) {
        transcribe_whisper_chunk_trace tr;
        transcribe_whisper_chunk_trace_init(&tr);
        stop_if_error(transcribe_get_whisper_chunk_trace(s, i, &tr), "reading whisper chunk trace");
        start[i]               = ms_to_s(tr.t0_ms);
        end[i]                 = ms_to_s(tr.t1_ms);
        temperature[i]         = (double) tr.temperature_used;
        compression_ratio[i]   = (double) tr.compression_ratio;
        avg_logprob[i]         = (double) tr.avg_logprob;
        no_speech_prob[i]      = (double) tr.no_speech_prob;
        no_speech_triggered[i] = (bool) tr.no_speech_triggered;
        n_fallbacks[i]         = (int) tr.n_fallbacks;
    }
    return List::create(_["start"] = start, _["end"] = end, _["temperature"] = temperature,
                        _["compression_ratio"] = compression_ratio, _["avg_logprob"] = avg_logprob,
                        _["no_speech_prob"] = no_speech_prob, _["no_speech_triggered"] = no_speech_triggered,
                        _["n_fallbacks"] = n_fallbacks);
}
