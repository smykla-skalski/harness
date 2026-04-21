use std::path::Path;

use super::resolve_project_input;
use tempfile::TempDir;

#[test]
fn returns_canonicalized_path_for_existing_dir() {
    let tmp = TempDir::new().expect("tempdir");
    let input = tmp.path().to_string_lossy().into_owned();
    let scope = resolve_project_input(&input).expect("resolve direct path");
    assert_eq!(
        scope.path(),
        tmp.path().canonicalize().expect("canonicalize")
    );
}

#[test]
fn errors_when_path_does_not_exist() {
    let result = resolve_project_input("/this/path/should/not/exist/anywhere");
    let Err(error) = result else {
        panic!("expected error for missing path");
    };
    assert!(
        error.to_string().contains("could not canonicalize"),
        "expected canonicalization error message, got {error}"
    );
}

#[cfg(target_os = "macos")]
#[test]
fn resolves_bookmark_from_harness_data_root() {
    use crate::sandbox::bookmarks::{self, Kind, PersistedStore, Record};

    let tmp = TempDir::new().expect("tempdir");
    harness_testkit::with_isolated_harness_env(tmp.path(), || {
        temp_env::with_var("HARNESS_SANDBOXED", Some("1"), || {
            let project_dir = tmp.path().join("repo");
            std::fs::create_dir_all(&project_dir).expect("create project dir");
            let bookmark_id = "B-project-input";
            let store_path = tmp.path().join("harness/bookmarks.json");
            bookmarks::save(
                &store_path,
                &PersistedStore {
                    schema_version: PersistedStore::CURRENT_SCHEMA_VERSION,
                    bookmarks: vec![Record {
                        id: bookmark_id.into(),
                        kind: Kind::ProjectRoot,
                        display_name: "repo".into(),
                        last_resolved_path: project_dir.display().to_string(),
                        bookmark_data: synthesize_bookmark(&project_dir),
                        created_at: chrono::Utc::now(),
                        last_accessed_at: chrono::Utc::now(),
                        stale_count: 0,
                    }],
                },
            )
            .expect("save bookmarks");

            let scope = resolve_project_input(bookmark_id).expect("resolve bookmark input");
            assert_eq!(
                scope.path().canonicalize().expect("canonicalize"),
                project_dir.canonicalize().expect("canonicalize")
            );
        });
    });
}

#[cfg(target_os = "macos")]
#[allow(unsafe_code)]
fn synthesize_bookmark(path: &Path) -> Vec<u8> {
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
