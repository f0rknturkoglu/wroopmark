// C ABI of wroopmark_core (see src/ffi.rs). JSON in, JSON out.
#pragma once

typedef struct WmHandle WmHandle;

/// Opens (or creates) the library directory. NULL on failure.
WmHandle *wm_open(const char *library_dir);
/// Runs one JSON command; release the result with wm_free.
char *wm_call(WmHandle *handle, const char *request_json);
void wm_free(char *s);
void wm_close(WmHandle *handle);
