#![cfg(target_os = "macos")]
#![allow(unsafe_code)]

use super::*;

#[test]
fn resolve_roundtrip_from_synthesized_bookmark() {
    let tmp = tempfile::tempdir().unwrap();
    let bytes = synthesize_bookmark(tmp.path(), true);
    let resolved = resolve(&bytes).expect("resolve must succeed");
    // On macOS /var is a symlink to /private/var; canonicalize both sides so
    // the comparison is stable regardless of which representation is used.
    let expected = tmp.path().canonicalize().unwrap();
    let got = resolved.path().canonicalize().unwrap();
    assert_eq!(got, expected);
    assert!(!resolved.is_stale());
}

#[test]
fn plain_bookmark_can_bootstrap_security_scoped_bookmark() {
    let tmp = tempfile::tempdir().unwrap();
    let plain = synthesize_bookmark(tmp.path(), false);
    let resolved = resolve_without_security_scope(&plain).expect("plain resolve must succeed");
    let helper_bookmark =
        create_security_scoped_bookmark(resolved.path()).expect("helper bookmark create");
    let helper_resolved = resolve(&helper_bookmark).expect("helper bookmark resolve");
    assert_eq!(
        helper_resolved.path().canonicalize().unwrap(),
        tmp.path().canonicalize().unwrap()
    );
}

#[test]
fn is_sandboxed_reads_env() {
    let orig = std::env::var_os("HARNESS_SANDBOXED");
    // SAFETY: single-threaded test binary; no other threads read this var concurrently.
    unsafe { std::env::set_var("HARNESS_SANDBOXED", "1") };
    assert!(is_sandboxed());
    unsafe { std::env::remove_var("HARNESS_SANDBOXED") };
    assert!(!is_sandboxed());
    if let Some(v) = orig {
        unsafe { std::env::set_var("HARNESS_SANDBOXED", v) };
    }
}

/// Synthesize a security-scoped bookmark for `path` using CFURL APIs.
///
/// The test binary is unsandboxed so the bookmark lacks real extension rights,
/// but the CFURL round-trip is sufficient to verify `resolve`.
fn synthesize_bookmark(path: &std::path::Path, with_security_scope: bool) -> Vec<u8> {
    use core_foundation::base::TCFType;
    use core_foundation::data::CFData;
    use core_foundation::url::{
        CFURL, CFURLCreateBookmarkData, kCFURLBookmarkCreationWithSecurityScope,
    };

    let cf_url = CFURL::from_path(path, true).expect("CFURL from path");
    let mut err = std::ptr::null_mut();
    // SAFETY: cf_url is a valid CFURL; null allocator/relative_to/keys are valid sentinels.
    let data_ref = unsafe {
        CFURLCreateBookmarkData(
            std::ptr::null(),
            cf_url.as_concrete_TypeRef(),
            if with_security_scope {
                kCFURLBookmarkCreationWithSecurityScope
            } else {
                0
            },
            std::ptr::null(),
            std::ptr::null(),
            &mut err,
        )
    };
    assert!(!data_ref.is_null(), "CFURLCreateBookmarkData returned null");
    // SAFETY: data_ref is a non-null +1-retain CFDataRef from the call above.
    let cf_data = unsafe { CFData::wrap_under_create_rule(data_ref) };
    cf_data.bytes().to_vec()
}
