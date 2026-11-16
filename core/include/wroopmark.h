// C ABI of wroopmark_core (see src/ffi.rs). JSON in, JSON out.
#pragma once

typedef struct WmHandle WmHandle;

/// Opens (or creates) the library directory. NULL on failure.
WmHandle *wm_open(const char *library_dir);
/// Runs one JSON command; release the result with wm_free.
char *wm_call(WmHandle *handle, const char *request_json);
void wm_free(char *s);
void wm_close(WmHandle *handle);

typedef void (*WmAiOut)(void *ctx, const char *json);
typedef void (*WmAiFn)(const char *request_json, void *ctx, WmAiOut out);
/// Optional in-process AI handler (used on iOS where subprocesses cannot be spawned).
void wm_set_ai(WmAiFn fn);
