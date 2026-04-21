use std::fs;
use std::path::Path;

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse as _;
use tempfile::TempDir;

use crate::daemon::protocol::AdoptSessionRequest;
use crate::sandbox::bookmarks::{self, Kind, PersistedStore, Record};
use crate::session::types::CURRENT_VERSION;
use crate::workspace::adopter::AdoptionError;

use super::{adoption_error_response, post_session_adopt};
use crate::daemon::http::tests::{auth_headers, response_json, test_http_state_with_db};

fn write_valid_session(root: &std::path::Path, sid: &str, origin: &str) {
    fs::create_dir_all(root.join("workspace")).unwrap();
    fs::create_dir_all(root.join("memory")).unwrap();
    let state = format!(
        "{{\"schema_version\":{CURRENT_VERSION},\"session_id\":\"{sid}\",\"project_name\":\"demo\",\
          \"origin_path\":\"{origin}\",\"worktree_path\":\"\",\"shared_path\":\"\",\
          \"branch_ref\":\"harness/{sid}\",\"title\":\"t\",\"context\":\"c\",\
          \"status\":\"active\",\"created_at\":\"2026-04-20T00:00:00Z\",\
          \"updated_at\":\"2026-04-20T00:00:00Z\"}}"
    );
    fs::write(root.join("state.json"), state).unwrap();
    fs::write(root.join(".origin"), origin).unwrap();
}

fn write_bookmarks_store(path: &Path, bookmarks: Vec<Record>) {
    bookmarks::save(
        path,
        &PersistedStore {
            schema_version: PersistedStore::CURRENT_SCHEMA_VERSION,
            bookmarks,
        },
    )
    .unwrap();
}

#[test]
fn returns_200_on_valid_session() {
    let tmp = TempDir::new().unwrap();

    harness_testkit::with_isolated_harness_env(tmp.path(), || {
        // Build a B-layout session directory; keep it inside the daemon's
        // data root so external_origin stays None.
        let data_root = tmp.path().join("harness");
        let sessions_dir = data_root.join("sessions");
        let session_dir = sessions_dir.join("demo/abc12345");
        let origin = tmp.path().join("src/demo");
        fs::create_dir_all(&session_dir).unwrap();
        fs::create_dir_all(&origin).unwrap();
        write_valid_session(&session_dir, "abc12345", origin.to_str().unwrap());

        let state = test_http_state_with_db();
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let response = post_session_adopt(
                auth_headers(),
                State(state),
                Json(AdoptSessionRequest {
                    bookmark_id: None,
                    session_root: session_dir.to_string_lossy().into_owned(),
                }),
            )
            .await;

            let (status, body) = response_json(response).await;
            assert_eq!(status, StatusCode::OK);
            assert_eq!(body["state"]["session_id"].as_str(), Some("abc12345"));
        });
    });
}

#[test]
fn returns_200_on_valid_session_when_sandboxed_without_bookmark() {
    let tmp = TempDir::new().unwrap();

    harness_testkit::with_isolated_harness_env(tmp.path(), || {
        temp_env::with_var("HARNESS_SANDBOXED", Some("1"), || {
            let data_root = tmp.path().join("harness");
            let sessions_dir = data_root.join("sessions");
            let session_dir = sessions_dir.join("demo/abc12345");
            let origin = tmp.path().join("src/demo");
            fs::create_dir_all(&session_dir).unwrap();
            fs::create_dir_all(&origin).unwrap();
            write_valid_session(&session_dir, "abc12345", origin.to_str().unwrap());

            let state = test_http_state_with_db();
            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(async {
                let response = post_session_adopt(
                    auth_headers(),
                    State(state),
                    Json(AdoptSessionRequest {
                        bookmark_id: None,
                        session_root: session_dir.to_string_lossy().into_owned(),
                    }),
                )
                .await;

                let (status, body) = response_json(response).await;
                assert_eq!(status, StatusCode::OK);
                assert_eq!(body["state"]["session_id"].as_str(), Some("abc12345"));
            });
        });
    });
}

#[cfg(target_os = "macos")]
#[test]
fn returns_200_on_valid_session_when_sandboxed_with_bookmark() {
    let tmp = TempDir::new().unwrap();

    harness_testkit::with_isolated_harness_env(tmp.path(), || {
        temp_env::with_var("HARNESS_SANDBOXED", Some("1"), || {
            let data_root = tmp.path().join("harness");
            let bookmarks_path = data_root.join("bookmarks.json");
            let sessions_dir = data_root.join("sessions");
            let session_dir = sessions_dir.join("demo/abc12345");
            let origin = tmp.path().join("src/demo");
            fs::create_dir_all(&session_dir).unwrap();
            fs::create_dir_all(&origin).unwrap();
            write_valid_session(&session_dir, "abc12345", origin.to_str().unwrap());

            let bookmark_id = "B-session-abc12345";
            write_bookmarks_store(
                &bookmarks_path,
                vec![Record {
                    id: bookmark_id.into(),
                    kind: Kind::SessionDirectory,
                    display_name: "demo session".into(),
                    last_resolved_path: session_dir.to_string_lossy().into_owned(),
                    bookmark_data: synthesize_bookmark(&session_dir),
                    created_at: chrono::Utc::now(),
                    last_accessed_at: chrono::Utc::now(),
                    stale_count: 0,
                }],
            );

            let bogus_session_root = tmp.path().join("missing/session/path");
            let state = test_http_state_with_db();
            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(async {
                let response = post_session_adopt(
                    auth_headers(),
                    State(state),
                    Json(AdoptSessionRequest {
                        bookmark_id: Some(bookmark_id.into()),
                        session_root: bogus_session_root.to_string_lossy().into_owned(),
                    }),
                )
                .await;

                let (status, body) = response_json(response).await;
                assert_eq!(status, StatusCode::OK);
                assert_eq!(body["state"]["session_id"].as_str(), Some("abc12345"));
            });
        });
    });
}

#[test]
fn returns_409_on_duplicate() {
    let tmp = TempDir::new().unwrap();

    harness_testkit::with_isolated_harness_env(tmp.path(), || {
        let sessions_dir = tmp.path().join("harness/sessions");
        let session_dir = sessions_dir.join("demo/abc12345");
        let origin = tmp.path().join("src/demo");
        fs::create_dir_all(&session_dir).unwrap();
        fs::create_dir_all(&origin).unwrap();
        write_valid_session(&session_dir, "abc12345", origin.to_str().unwrap());

        let state = test_http_state_with_db();
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            // First adopt — must succeed.
            let first = post_session_adopt(
                auth_headers(),
                State(state.clone()),
                Json(AdoptSessionRequest {
                    bookmark_id: None,
                    session_root: session_dir.to_string_lossy().into_owned(),
                }),
            )
            .await;
            let (first_status, _) = response_json(first).await;
            assert_eq!(first_status, StatusCode::OK);

            // Second adopt — must conflict.
            let second = post_session_adopt(
                auth_headers(),
                State(state),
                Json(AdoptSessionRequest {
                    bookmark_id: None,
                    session_root: session_dir.to_string_lossy().into_owned(),
                }),
            )
            .await;
            let (status, body) = response_json(second).await;
            assert_eq!(status, StatusCode::CONFLICT);
            assert_eq!(body["error"].as_str(), Some("already-attached"));
            assert_eq!(body["session_id"].as_str(), Some("abc12345"));
        });
    });
}

#[test]
fn returns_422_on_layout_violation() {
    let tmp = TempDir::new().unwrap();
    // Session directory exists but is missing workspace/ — probe will fail.
    let session_dir = tmp.path().join("demo/abc12345");
    fs::create_dir_all(&session_dir).unwrap();

    harness_testkit::with_isolated_harness_env(tmp.path(), || {
        let state = test_http_state_with_db();
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let response = post_session_adopt(
                auth_headers(),
                State(state),
                Json(AdoptSessionRequest {
                    bookmark_id: None,
                    session_root: session_dir.to_string_lossy().into_owned(),
                }),
            )
            .await;
            let (status, body) = response_json(response).await;
            assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
            assert_eq!(body["error"].as_str(), Some("layout-violation"));
            assert!(
                body["reason"].as_str().map_or(false, |r| !r.is_empty()),
                "reason must be non-empty"
            );
        });
    });
}

/// Sanity check: `adoption_error_response` maps `LayoutViolation` to 422.
/// This test avoids the full handler + tokio plumbing when only error mapping
/// needs coverage.
#[tokio::test]
async fn adoption_error_response_maps_layout_violation_to_422() {
    let response = adoption_error_response(&AdoptionError::LayoutViolation {
        reason: "missing workspace/".into(),
    });
    let (status, body) = response_json(response.into_response()).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(body["error"].as_str(), Some("layout-violation"));
    assert_eq!(body["reason"].as_str(), Some("missing workspace/"));
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
