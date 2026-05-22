use super::*;

#[test]
fn list_request_normalizes_pull_request_id() {
    let request = DependencyUpdatesFilesListRequest {
        pull_request_id: "  PR_kwDOABC123  ".to_string(),
        force_refresh: false,
    };
    assert_eq!(request.normalized_pull_request_id(), "PR_kwDOABC123");
}

#[test]
fn list_request_normalize_empty_when_blank() {
    let request = DependencyUpdatesFilesListRequest {
        pull_request_id: "    ".to_string(),
        force_refresh: false,
    };
    assert!(request.normalized_pull_request_id().is_empty());
}

#[test]
fn parse_change_type_known_values() {
    assert_eq!(
        DependencyUpdateFileChangeType::parse("ADDED"),
        DependencyUpdateFileChangeType::Added
    );
    assert_eq!(
        DependencyUpdateFileChangeType::parse("DELETED"),
        DependencyUpdateFileChangeType::Deleted
    );
    assert_eq!(
        DependencyUpdateFileChangeType::parse("MODIFIED"),
        DependencyUpdateFileChangeType::Modified
    );
    assert_eq!(
        DependencyUpdateFileChangeType::parse("RENAMED"),
        DependencyUpdateFileChangeType::Renamed
    );
    assert_eq!(
        DependencyUpdateFileChangeType::parse("COPIED"),
        DependencyUpdateFileChangeType::Copied
    );
    assert_eq!(
        DependencyUpdateFileChangeType::parse("CHANGED"),
        DependencyUpdateFileChangeType::Changed
    );
}

#[test]
fn parse_change_type_unknown_falls_back_to_other() {
    assert_eq!(
        DependencyUpdateFileChangeType::parse("FUTURE_VALUE"),
        DependencyUpdateFileChangeType::Other
    );
    assert_eq!(
        DependencyUpdateFileChangeType::parse(""),
        DependencyUpdateFileChangeType::Other
    );
}

#[test]
fn parse_viewed_state_known_values() {
    assert_eq!(
        DependencyUpdateFileViewedState::parse("VIEWED"),
        DependencyUpdateFileViewedState::Viewed
    );
    assert_eq!(
        DependencyUpdateFileViewedState::parse("DISMISSED"),
        DependencyUpdateFileViewedState::Dismissed
    );
    assert_eq!(
        DependencyUpdateFileViewedState::parse("UNVIEWED"),
        DependencyUpdateFileViewedState::Unviewed
    );
}

#[test]
fn parse_viewed_state_unknown_falls_back_to_unviewed() {
    assert_eq!(
        DependencyUpdateFileViewedState::parse("FUTURE_VALUE"),
        DependencyUpdateFileViewedState::Unviewed
    );
}

#[test]
fn infer_language_swift_extension() {
    assert_eq!(
        infer_language("apps/harness-monitor-macos/Foo.swift"),
        HarnessCodeLanguage::Swift
    );
}

#[test]
fn infer_language_rust_extension() {
    assert_eq!(infer_language("src/lib.rs"), HarnessCodeLanguage::Rust);
}

#[test]
fn infer_language_shell_extensions() {
    assert_eq!(infer_language("bin/build.sh"), HarnessCodeLanguage::Shell);
    assert_eq!(infer_language("scripts/x.bash"), HarnessCodeLanguage::Shell);
    assert_eq!(infer_language("zshrc.zsh"), HarnessCodeLanguage::Shell);
    assert_eq!(infer_language("fishrc.fish"), HarnessCodeLanguage::Shell);
}

#[test]
fn infer_language_json_extensions() {
    assert_eq!(infer_language("config.json"), HarnessCodeLanguage::Json);
    assert_eq!(infer_language("config.jsonc"), HarnessCodeLanguage::Json);
}

#[test]
fn infer_language_yaml_extensions() {
    assert_eq!(infer_language(".github/x.yml"), HarnessCodeLanguage::Yaml);
    assert_eq!(infer_language(".github/y.yaml"), HarnessCodeLanguage::Yaml);
}

#[test]
fn infer_language_markdown_extensions() {
    assert_eq!(infer_language("docs/Guide.md"), HarnessCodeLanguage::Markdown);
    assert_eq!(infer_language("docs/Guide.MARKDOWN"), HarnessCodeLanguage::Markdown);
    assert_eq!(infer_language("README.md"), HarnessCodeLanguage::Markdown);
}

#[test]
fn infer_language_diff_extensions() {
    assert_eq!(infer_language("change.patch"), HarnessCodeLanguage::Diff);
    assert_eq!(infer_language("change.diff"), HarnessCodeLanguage::Diff);
}

#[test]
fn infer_language_filename_special_cases() {
    assert_eq!(
        infer_language("Dockerfile"),
        HarnessCodeLanguage::Generic
    );
    assert_eq!(
        infer_language("path/to/Dockerfile"),
        HarnessCodeLanguage::Generic
    );
    assert_eq!(
        infer_language("Makefile"),
        HarnessCodeLanguage::Generic
    );
    assert_eq!(
        infer_language("package.json"),
        HarnessCodeLanguage::Json
    );
    assert_eq!(
        infer_language("package-lock.json"),
        HarnessCodeLanguage::Json
    );
    assert_eq!(
        infer_language("tsconfig.json"),
        HarnessCodeLanguage::Json
    );
}

#[test]
fn infer_language_unknown_extension_is_generic() {
    assert_eq!(
        infer_language("path/to/binary.exe"),
        HarnessCodeLanguage::Generic
    );
    assert_eq!(
        infer_language("LICENSE"),
        HarnessCodeLanguage::Generic
    );
    assert_eq!(
        infer_language("path/no-extension"),
        HarnessCodeLanguage::Generic
    );
}

#[test]
fn files_list_response_serializes_round_trip() {
    let response = DependencyUpdatesFilesListResponse {
        pull_request_id: "PR_kwDOABC".into(),
        head_ref_oid: "abc123".into(),
        viewer_can_mark_viewed: true,
        files: vec![DependencyUpdateFile {
            path: "src/lib.rs".into(),
            previous_path: None,
            change_type: DependencyUpdateFileChangeType::Modified,
            additions: 12,
            deletions: 3,
            viewer_viewed_state: DependencyUpdateFileViewedState::Unviewed,
            is_binary: false,
            language_hint: HarnessCodeLanguage::Rust,
            mode_change: None,
        }],
        fetched_at: "2026-05-22T10:00:00Z".into(),
        pagination_complete: true,
        rate_limit_snapshot: Some(DependencyUpdatesRateLimitSnapshot {
            remaining: 4998,
            limit: 5000,
            reset_at: Some("2026-05-22T11:00:00Z".into()),
            cost: Some(1),
        }),
    };
    let json = serde_json::to_string(&response).expect("serialize");
    let parsed: DependencyUpdatesFilesListResponse =
        serde_json::from_str(&json).expect("deserialize");
    assert_eq!(parsed, response);
}

#[test]
fn files_list_response_pagination_complete_defaults_true_when_absent() {
    // Older daemon responses that don't carry the field should still
    // deserialize and read pagination_complete = true so the caller
    // doesn't surface a spurious warning.
    let json = r#"{
        "pull_request_id": "PR_1",
        "head_ref_oid": "abc",
        "viewer_can_mark_viewed": true,
        "files": [],
        "fetched_at": "2026-05-22T10:00:00Z"
    }"#;
    let parsed: DependencyUpdatesFilesListResponse =
        serde_json::from_str(json).expect("deserialize");
    assert!(parsed.pagination_complete);
}

#[test]
fn files_list_response_pagination_partial_survives_round_trip() {
    let response = DependencyUpdatesFilesListResponse {
        pull_request_id: "PR_1".into(),
        head_ref_oid: "abc".into(),
        viewer_can_mark_viewed: true,
        files: vec![],
        fetched_at: "2026-05-22T10:00:00Z".into(),
        pagination_complete: false,
        rate_limit_snapshot: None,
    };
    let json = serde_json::to_string(&response).expect("serialize");
    let parsed: DependencyUpdatesFilesListResponse =
        serde_json::from_str(&json).expect("deserialize");
    assert!(!parsed.pagination_complete);
}

#[test]
fn files_list_request_serializes_force_refresh_default() {
    let request = DependencyUpdatesFilesListRequest {
        pull_request_id: "PR_1".into(),
        force_refresh: false,
    };
    let json = serde_json::to_value(&request).expect("serialize");
    assert_eq!(json["pull_request_id"], "PR_1");
    assert_eq!(json["force_refresh"], false);
}

#[test]
fn files_list_response_omits_none_rate_limit() {
    let response = DependencyUpdatesFilesListResponse {
        pull_request_id: "PR_1".into(),
        head_ref_oid: "abc".into(),
        viewer_can_mark_viewed: true,
        files: vec![],
        fetched_at: "2026-05-22T10:00:00Z".into(),
        pagination_complete: true,
        rate_limit_snapshot: None,
    };
    let json = serde_json::to_value(&response).expect("serialize");
    assert!(json.get("rate_limit_snapshot").is_none());
}
