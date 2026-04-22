#![cfg(target_os = "macos")]

use std::path::Path;
use std::ptr;

use harness::sandbox::bookmarks::{Kind, PersistedStore, Record, load, save};
use harness::sandbox::resolver::resolve;
use tempfile::TempDir;

#[test]
fn roundtrip_through_shared_json() {
    let target = TempDir::new().unwrap();
    let container = TempDir::new().unwrap();
    let json_path = container.path().join("sandbox/bookmarks.json");

    let bookmark_bytes = synthesize_bookmark(target.path());
    let now = chrono::Utc::now();
    let store = PersistedStore {
        schema_version: PersistedStore::CURRENT_SCHEMA_VERSION,
        bookmarks: vec![Record {
            id: "B-integ".into(),
            kind: Kind::ProjectRoot,
            display_name: "integ".into(),
            last_resolved_path: target.path().display().to_string(),
            bookmark_data: bookmark_bytes,
            handoff_bookmark_data: None,
            created_at: now,
            last_accessed_at: now,
            stale_count: 0,
        }],
    };
    save(&json_path, &store).expect("save");

    let reloaded = load(&json_path).expect("load");
    let bytes = &reloaded.bookmarks[0].bookmark_data;
    let resolved = resolve(bytes).expect("resolve");
    assert_eq!(
        resolved
            .path()
            .canonicalize()
            .expect("canonicalize resolved"),
        target.path().canonicalize().expect("canonicalize target"),
    );
}

#[expect(unsafe_code, reason = "Core Foundation FFI for test fixture")]
fn synthesize_bookmark(path: &Path) -> Vec<u8> {
    use core_foundation::base::TCFType;
    use core_foundation::data::CFData;
    use core_foundation::error::{CFError, CFErrorRef};
    use core_foundation::url::{
        CFURL, CFURLCreateBookmarkData, kCFURLBookmarkCreationWithSecurityScope,
    };

    let cf_url = CFURL::from_path(path, true).expect("CFURL from path");
    let mut err: CFErrorRef = ptr::null_mut();
    // SAFETY:
    // - `cf_url` is a valid CFURL that outlives the call.
    // - Null allocator/relative_to/resourceKeys are documented-valid sentinels
    //   for CFURLCreateBookmarkData.
    // - `&mut err` is an exclusive pointer owned by the caller for the
    //   duration of the FFI call; CF writes at most one CFErrorRef into it.
    let data_ref = unsafe {
        CFURLCreateBookmarkData(
            ptr::null(),
            cf_url.as_concrete_TypeRef(),
            kCFURLBookmarkCreationWithSecurityScope,
            ptr::null(),
            ptr::null(),
            ptr::from_mut(&mut err),
        )
    };
    if data_ref.is_null() {
        // SAFETY: CF sets `err` under the Create Rule on failure, so take
        // ownership to release it via Drop.
        let cf_err = unsafe { CFError::wrap_under_create_rule(err) };
        panic!("CFURLCreateBookmarkData failed: {cf_err:?}");
    }
    if !err.is_null() {
        // SAFETY: Same Create Rule contract; release any spurious error
        // returned alongside a successful data_ref to avoid leaking it.
        let _ = unsafe { CFError::wrap_under_create_rule(err) };
    }
    // SAFETY: `data_ref` is a non-null CFDataRef returned under the Create
    // Rule (+1 retain); wrap_under_create_rule takes ownership without
    // adding a retain, and Drop will release it.
    let cf_data = unsafe { CFData::wrap_under_create_rule(data_ref) };
    cf_data.bytes().to_vec()
}
