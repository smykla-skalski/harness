//! macOS-only resolver for security-scoped bookmarks.

#![cfg(target_os = "macos")]
#![expect(
    unsafe_code,
    reason = "Core Foundation FFI for security-scoped bookmarks"
)]

use std::env;
use std::path::{Path, PathBuf};
use std::ptr;

use core_foundation::base::{Boolean, TCFType};
use core_foundation::data::CFData;
use core_foundation::error::CFError;
use core_foundation::url::{
    CFURL, CFURLCreateBookmarkData, CFURLCreateByResolvingBookmarkData,
    CFURLStartAccessingSecurityScopedResource, CFURLStopAccessingSecurityScopedResource,
    kCFURLBookmarkCreationWithSecurityScope, kCFURLBookmarkResolutionWithSecurityScope,
    kCFURLBookmarkResolutionWithoutUIMask,
};

use crate::sandbox::bookmarks::BookmarkError;

/// A resolved bookmark with an active security-scoped access grant.
///
/// Dropping this value releases the grant via
/// `CFURLStopAccessingSecurityScopedResource`.
pub struct ResolvedBookmark {
    path: PathBuf,
    is_stale: bool,
    _scope: Option<BookmarkScope>,
}

impl ResolvedBookmark {
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Returns `true` when the OS reports the bookmark as stale.
    /// Callers should re-create the bookmark and persist fresh bytes.
    #[must_use]
    pub fn is_stale(&self) -> bool {
        self.is_stale
    }
}

fn describe_cf_error(err: &CFError) -> String {
    let desc = err.description();
    let text: String = desc.to_string();
    format!("code={} description={text}", err.code())
}

/// RAII guard for `CFURLStartAccessingSecurityScopedResource`.
pub struct BookmarkScope {
    cf_url: CFURL,
    started: bool,
}

impl BookmarkScope {
    fn start(cf_url: CFURL) -> Self {
        // SAFETY: cf_url is a valid CFURL created by CFURLCreateByResolvingBookmarkData.
        let started =
            unsafe { CFURLStartAccessingSecurityScopedResource(cf_url.as_concrete_TypeRef()) != 0 };
        Self { cf_url, started }
    }
}

impl Drop for BookmarkScope {
    fn drop(&mut self) {
        if self.started {
            // SAFETY: cf_url remains valid for our lifetime; CFURLStart was called in ::start.
            unsafe {
                CFURLStopAccessingSecurityScopedResource(self.cf_url.as_concrete_TypeRef());
            }
        }
    }
}

/// Return `true` when the process runs under the macOS app sandbox.
///
/// Gated on the `HARNESS_SANDBOXED=1` env var set by the launch agent plist.
#[must_use]
pub fn is_sandboxed() -> bool {
    env::var_os("HARNESS_SANDBOXED").is_some()
}

/// Resolve a security-scoped bookmark's bytes to a filesystem path + active scope.
///
/// # Errors
///
/// Returns [`BookmarkError::Resolution`] when the Core Foundation call fails
/// (invalid bytes, path no longer reachable, etc.).
pub fn resolve(bytes: &[u8]) -> Result<ResolvedBookmark, BookmarkError> {
    resolve_internal(
        bytes,
        kCFURLBookmarkResolutionWithSecurityScope | kCFURLBookmarkResolutionWithoutUIMask,
        true,
    )
}

/// Resolve bookmark bytes without requesting a security scope.
///
/// This is used to bootstrap helper-owned security-scoped bookmarks from the
/// shared app store, whose bookmark data may be readable across processes only
/// as a regular bookmark.
///
/// # Errors
///
/// Returns [`BookmarkError::Resolution`] when the bookmark cannot be decoded.
pub fn resolve_without_security_scope(bytes: &[u8]) -> Result<ResolvedBookmark, BookmarkError> {
    resolve_internal(bytes, kCFURLBookmarkResolutionWithoutUIMask, false)
}

/// Create a helper-owned security-scoped bookmark for `path`.
///
/// # Errors
///
/// Returns [`BookmarkError::Creation`] when Core Foundation rejects the
/// bookmark generation call.
pub fn create_security_scoped_bookmark(path: &Path) -> Result<Vec<u8>, BookmarkError> {
    let cf_url = CFURL::from_path(path, true)
        .ok_or_else(|| BookmarkError::Creation("CFURL::from_path failed".into()))?;
    let mut err = ptr::null_mut();
    // SAFETY: cf_url is valid and the null pointer arguments are accepted
    // sentinels for allocator/relative URL/resource keys.
    let data_ref = unsafe {
        CFURLCreateBookmarkData(
            ptr::null(),
            cf_url.as_concrete_TypeRef(),
            kCFURLBookmarkCreationWithSecurityScope,
            ptr::null(),
            ptr::null(),
            &raw mut err,
        )
    };
    if data_ref.is_null() {
        let detail = if err.is_null() {
            "no CFError provided".to_string()
        } else {
            // SAFETY: err is a +1-retain CFErrorRef from the call above.
            let cf_err = unsafe { CFError::wrap_under_create_rule(err) };
            describe_cf_error(&cf_err)
        };
        return Err(BookmarkError::Creation(format!(
            "CFURLCreateBookmarkData failed: {detail}"
        )));
    }
    // SAFETY: data_ref is a non-null +1-retain CFDataRef from the call above.
    let cf_data = unsafe { CFData::wrap_under_create_rule(data_ref) };
    Ok(cf_data.bytes().to_vec())
}

fn resolve_internal(
    bytes: &[u8],
    options: usize,
    start_scope: bool,
) -> Result<ResolvedBookmark, BookmarkError> {
    let cf_data = CFData::from_buffer(bytes);
    let mut is_stale: Boolean = 0;
    let mut err = ptr::null_mut();
    // SAFETY: all pointer arguments are either null (valid sentinel) or valid
    // CF references.  The returned CFURLRef is either null (on error) or a
    // +1-retain object consumed by CFURL::wrap_under_create_rule.
    let cf_url_ref = unsafe {
        CFURLCreateByResolvingBookmarkData(
            ptr::null(),
            cf_data.as_concrete_TypeRef(),
            options,
            ptr::null(),
            ptr::null(),
            &raw mut is_stale,
            &raw mut err,
        )
    };
    if cf_url_ref.is_null() {
        let detail = if err.is_null() {
            "no CFError provided".to_string()
        } else {
            // SAFETY: err is a +1-retain CFErrorRef from the call above; wrap
            // under the create rule so CFRelease fires on drop (prevents leak).
            let cf_err = unsafe { CFError::wrap_under_create_rule(err) };
            describe_cf_error(&cf_err)
        };
        return Err(BookmarkError::Resolution(format!(
            "CFURLCreateByResolvingBookmarkData failed: {detail}"
        )));
    }
    // SAFETY: cf_url_ref is a non-null +1-retain CFURLRef from the call above.
    let cf_url = unsafe { CFURL::wrap_under_create_rule(cf_url_ref) };
    let path = cf_url
        .to_path()
        .ok_or_else(|| BookmarkError::Resolution("CFURL::to_path failed".into()))?;
    let scope = start_scope.then(|| BookmarkScope::start(cf_url));
    Ok(ResolvedBookmark {
        path,
        is_stale: is_stale != 0,
        _scope: scope,
    })
}

#[cfg(test)]
mod tests;
