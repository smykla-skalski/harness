#![cfg(target_os = "macos")]

use harness::sandbox::bookmarks::{Kind, PersistedStore, Record, load, save};
use harness::sandbox::resolver::resolve;
use tempfile::TempDir;

#[test]
fn roundtrip_through_shared_json() {
    let target = TempDir::new().unwrap();
    let container = TempDir::new().unwrap();
    let json_path = container.path().join("sandbox/bookmarks.json");

    let bookmark_bytes = synthesize_bookmark(target.path());
    let store = PersistedStore {
        schema_version: PersistedStore::CURRENT_SCHEMA_VERSION,
        bookmarks: vec![Record {
            id: "B-integ".into(),
            kind: Kind::ProjectRoot,
            display_name: "integ".into(),
            last_resolved_path: target.path().display().to_string(),
            bookmark_data: bookmark_bytes,
            created_at: chrono::Utc::now(),
            last_accessed_at: chrono::Utc::now(),
            stale_count: 0,
        }],
    };
    save(&json_path, &store).unwrap();

    let reloaded = load(&json_path).unwrap();
    let bytes = &reloaded.bookmarks[0].bookmark_data;
    let resolved = resolve(bytes).expect("resolve");
    assert_eq!(
        resolved.path().canonicalize().unwrap(),
        target.path().canonicalize().unwrap(),
    );
}

#[expect(unsafe_code, reason = "Core Foundation FFI for test fixture")]
fn synthesize_bookmark(path: &std::path::Path) -> Vec<u8> {
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
            kCFURLBookmarkCreationWithSecurityScope,
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
