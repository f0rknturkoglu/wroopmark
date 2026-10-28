//! C ABI for the Swift apps. Four functions, JSON in and out:
//!
//! ```c
//! WmHandle *wm_open(const char *library_dir);
//! char     *wm_call(WmHandle *h, const char *request_json);
//! void      wm_free(char *s);
//! void      wm_close(WmHandle *h);
//! ```
//!
//! Same shape as forkjob: one JSON entry point keeps the boundary tiny and
//! versionable. Panics never cross it; they come back as errors.

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::Arc;

use crate::api::Library;

pub struct WmHandle {
    lib: Arc<Library>,
}

/// Open (or create) the library in `library_dir`. Returns NULL on failure.
///
/// # Safety
/// `library_dir` must be a valid NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_open(library_dir: *const c_char) -> *mut WmHandle {
    if library_dir.is_null() {
        return std::ptr::null_mut();
    }
    let result = catch_unwind(|| {
        let path = unsafe { CStr::from_ptr(library_dir) }.to_str().ok()?;
        let lib = Library::open(Path::new(path)).ok()?;
        lib.kick_media();
        Some(Box::into_raw(Box::new(WmHandle { lib })))
    });
    match result {
        Ok(Some(ptr)) => ptr,
        _ => std::ptr::null_mut(),
    }
}

/// Run one JSON command. The returned string must be released with `wm_free`.
///
/// # Safety
/// `handle` must come from `wm_open`; `request` must be NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_call(handle: *mut WmHandle, request: *const c_char) -> *mut c_char {
    let response = if handle.is_null() || request.is_null() {
        r#"{"ok":false,"error":"geçersiz tutamaç"}"#.to_string()
    } else {
        let h = unsafe { &*handle };
        let req = unsafe { CStr::from_ptr(request) }.to_string_lossy().into_owned();
        match catch_unwind(AssertUnwindSafe(|| crate::api::handle(&h.lib, &req))) {
            Ok(v) => v.to_string(),
            Err(_) => r#"{"ok":false,"error":"çekirdek hata verdi (panic)"}"#.to_string(),
        }
    };
    CString::new(response).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// `s` must be a pointer returned by `wm_call`, freed at most once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

/// # Safety
/// `handle` must come from `wm_open` and is invalid afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_close(handle: *mut WmHandle) {
    if !handle.is_null() {
        let h = unsafe { Box::from_raw(handle) };
        h.lib.store().checkpoint();
    }
}
