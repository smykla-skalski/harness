//! Where the panel answers, under a subtree and at the origin root.
//!
//! The root case is the one worth covering in the live router rather than in
//! `normalize_base_path` alone: an empty base turns every `{base}/x` route
//! pattern into `/x`, and the one pattern that would come out as `""` has to be
//! left out or axum panics while the router is being built.

use axum::http::StatusCode;

use super::Harness;

#[tokio::test]
async fn the_entry_page_is_served_at_the_mount_point_with_or_without_a_slash() {
    let harness = Harness::new("ada").await;

    for path in ["/panel", "/panel/"] {
        let (status, body) = harness.get(path, None).await;

        assert_eq!(status, StatusCode::OK, "{path}");
        assert!(body.contains("harness-panel-base"), "{path}: {body}");
        assert!(body.contains(r#"content="/panel""#), "{path}: {body}");
    }
}

/// A reload or a bookmark of an app route has to reach the app, which only the
/// entry page can dispatch.
#[tokio::test]
async fn an_unknown_path_under_the_mount_point_falls_back_to_the_app() {
    let harness = Harness::new("ada").await;

    let (status, body) = harness.get("/panel/accounts", None).await;

    assert_eq!(status, StatusCode::OK);
    assert!(body.contains("<div id=\"app\">"), "{body}");
}

/// The daemon forwards only its companion prefix, but the panel must not serve
/// anything outside it even when reached directly over loopback.
#[tokio::test]
async fn nothing_is_served_outside_the_mount_point() {
    let harness = Harness::new("ada").await;

    for path in ["/", "/healthz", "/api/me", "/panelx/healthz"] {
        let (status, _) = harness.get(path, None).await;
        assert_eq!(status, StatusCode::NOT_FOUND, "{path} should not be served");
    }
}

async fn at_root() -> Harness {
    Harness::with_args("ada", |raw| raw.base_path = "/".to_owned()).await
}

#[tokio::test]
async fn a_root_panel_serves_its_entry_page_at_the_origin_root() {
    let harness = at_root().await;

    let (status, body) = harness.get("/", None).await;

    assert_eq!(status, StatusCode::OK);
    assert!(body.contains("<div id=\"app\">"), "{body}");
    // The mount point the app reads back, which at the root is nothing at all.
    // `panelUrl` then builds `/api/me` rather than `//api/me`.
    assert!(body.contains(r#"content="""#), "{body}");
}

#[tokio::test]
async fn a_root_panel_answers_its_api_without_a_prefix() {
    let harness = at_root().await;

    let (health, body) = harness.get("/healthz", None).await;
    let (me, _) = harness.get("/api/me", None).await;

    assert_eq!(health, StatusCode::OK);
    assert!(body.contains("\"status\":\"ok\""), "{body}");
    // Reached the route and found no session, rather than not reaching it.
    assert_eq!(me, StatusCode::UNAUTHORIZED);
}

/// Everything the panel does not answer itself is an app route, and at the root
/// that is the whole origin below it.
#[tokio::test]
async fn a_root_panel_falls_back_to_the_app_for_an_unknown_path() {
    let harness = at_root().await;

    let (status, body) = harness.get("/accounts", None).await;

    assert_eq!(status, StatusCode::OK);
    assert!(body.contains("<div id=\"app\">"), "{body}");
}
