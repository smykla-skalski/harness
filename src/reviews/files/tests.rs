use super::*;

#[test]
fn list_request_normalizes_pull_request_id() {
    let request = ReviewsFilesListRequest {
        pull_request_id: "  PR_kwDOABC123  ".to_string(),
        force_refresh: false,
    };
    assert_eq!(request.normalized_pull_request_id(), "PR_kwDOABC123");
}

#[test]
fn list_request_normalize_empty_when_blank() {
    let request = ReviewsFilesListRequest {
        pull_request_id: "    ".to_string(),
        force_refresh: false,
    };
    assert!(request.normalized_pull_request_id().is_empty());
}

#[test]
fn parse_change_type_known_values() {
    assert_eq!(
        ReviewFileChangeType::parse("ADDED"),
        ReviewFileChangeType::Added
    );
    assert_eq!(
        ReviewFileChangeType::parse("DELETED"),
        ReviewFileChangeType::Deleted
    );
    assert_eq!(
        ReviewFileChangeType::parse("MODIFIED"),
        ReviewFileChangeType::Modified
    );
    assert_eq!(
        ReviewFileChangeType::parse("RENAMED"),
        ReviewFileChangeType::Renamed
    );
    assert_eq!(
        ReviewFileChangeType::parse("COPIED"),
        ReviewFileChangeType::Copied
    );
    assert_eq!(
        ReviewFileChangeType::parse("CHANGED"),
        ReviewFileChangeType::Changed
    );
}

#[test]
fn parse_change_type_unknown_falls_back_to_other() {
    assert_eq!(
        ReviewFileChangeType::parse("FUTURE_VALUE"),
        ReviewFileChangeType::Other
    );
    assert_eq!(ReviewFileChangeType::parse(""), ReviewFileChangeType::Other);
}

#[test]
fn parse_viewed_state_known_values() {
    assert_eq!(
        ReviewFileViewedState::parse("VIEWED"),
        ReviewFileViewedState::Viewed
    );
    assert_eq!(
        ReviewFileViewedState::parse("DISMISSED"),
        ReviewFileViewedState::Dismissed
    );
    assert_eq!(
        ReviewFileViewedState::parse("UNVIEWED"),
        ReviewFileViewedState::Unviewed
    );
}

#[test]
fn parse_viewed_state_unknown_falls_back_to_unviewed() {
    assert_eq!(
        ReviewFileViewedState::parse("FUTURE_VALUE"),
        ReviewFileViewedState::Unviewed
    );
}

#[test]
fn infer_language_swift_extension() {
    assert_eq!(
        infer_language("apps/harness-monitor/Foo.swift"),
        HarnessCodeLanguage::Swift
    );
}

#[test]
fn infer_language_rust_extension() {
    assert_eq!(infer_language("src/lib.rs"), HarnessCodeLanguage::Rust);
}

#[test]
fn infer_language_go_extension() {
    assert_eq!(infer_language("cmd/main.go"), HarnessCodeLanguage::Go);
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
    assert_eq!(
        infer_language("docs/Guide.md"),
        HarnessCodeLanguage::Markdown
    );
    assert_eq!(
        infer_language("docs/Guide.MARKDOWN"),
        HarnessCodeLanguage::Markdown
    );
    assert_eq!(infer_language("README.md"), HarnessCodeLanguage::Markdown);
}

#[test]
fn infer_language_diff_extensions() {
    assert_eq!(infer_language("change.patch"), HarnessCodeLanguage::Diff);
    assert_eq!(infer_language("change.diff"), HarnessCodeLanguage::Diff);
}

#[test]
fn infer_language_filename_special_cases() {
    assert_eq!(infer_language("Dockerfile"), HarnessCodeLanguage::Generic);
    assert_eq!(
        infer_language("path/to/Dockerfile"),
        HarnessCodeLanguage::Generic
    );
    assert_eq!(infer_language("Makefile"), HarnessCodeLanguage::Generic);
    assert_eq!(infer_language("package.json"), HarnessCodeLanguage::Json);
    assert_eq!(
        infer_language("package-lock.json"),
        HarnessCodeLanguage::Json
    );
    assert_eq!(infer_language("tsconfig.json"), HarnessCodeLanguage::Json);
}

#[test]
fn infer_language_unknown_extension_is_generic() {
    assert_eq!(
        infer_language("path/to/binary.exe"),
        HarnessCodeLanguage::Generic
    );
    assert_eq!(infer_language("LICENSE"), HarnessCodeLanguage::Generic);
    assert_eq!(
        infer_language("path/no-extension"),
        HarnessCodeLanguage::Generic
    );
}

#[test]
fn files_list_response_serializes_round_trip() {
    let response = ReviewsFilesListResponse {
        pull_request_id: "PR_kwDOABC".into(),
        number: Some(42),
        head_ref_oid: "abc123".into(),
        head_ref_name: Some("renovate/foo".into()),
        base_ref_oid: Some("def456".into()),
        base_ref_name: Some("main".into()),
        repository_full_name: Some("owner/repo".into()),
        viewer_can_mark_viewed: true,
        files: vec![ReviewFile {
            path: "src/lib.rs".into(),
            previous_path: None,
            change_type: ReviewFileChangeType::Modified,
            additions: 12,
            deletions: 3,
            viewer_viewed_state: ReviewFileViewedState::Unviewed,
            is_binary: false,
            language_hint: HarnessCodeLanguage::Rust,
            mode_change: None,
        }, ReviewFile {
            path: "cmd/main.go".into(),
            previous_path: None,
            change_type: ReviewFileChangeType::Added,
            additions: 24,
            deletions: 0,
            viewer_viewed_state: ReviewFileViewedState::Viewed,
            is_binary: false,
            language_hint: HarnessCodeLanguage::Go,
            mode_change: None,
        }],
        fetched_at: "2026-05-22T10:00:00Z".into(),
        pagination_complete: true,
        rate_limit_snapshot: Some(ReviewsRateLimitSnapshot {
            remaining: 4998,
            limit: 5000,
            reset_at: Some("2026-05-22T11:00:00Z".into()),
            cost: Some(1),
        }),
    };
    let json = serde_json::to_string(&response).expect("serialize");
    let parsed: ReviewsFilesListResponse = serde_json::from_str(&json).expect("deserialize");
    assert_eq!(parsed, response);
}

#[test]
fn language_hint_go_serializes_round_trip() {
    let json = serde_json::to_string(&HarnessCodeLanguage::Go).expect("serialize");
    assert_eq!(json, "\"go\"");
    let parsed: HarnessCodeLanguage = serde_json::from_str(&json).expect("deserialize");
    assert_eq!(parsed, HarnessCodeLanguage::Go);
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
    let parsed: ReviewsFilesListResponse = serde_json::from_str(json).expect("deserialize");
    assert!(parsed.pagination_complete);
}

#[test]
fn files_list_response_pagination_partial_survives_round_trip() {
    let response = ReviewsFilesListResponse {
        pull_request_id: "PR_1".into(),
        number: None,
        head_ref_oid: "abc".into(),
        head_ref_name: None,
        base_ref_oid: None,
        base_ref_name: None,
        repository_full_name: None,
        viewer_can_mark_viewed: true,
        files: vec![],
        fetched_at: "2026-05-22T10:00:00Z".into(),
        pagination_complete: false,
        rate_limit_snapshot: None,
    };
    let json = serde_json::to_string(&response).expect("serialize");
    let parsed: ReviewsFilesListResponse = serde_json::from_str(&json).expect("deserialize");
    assert!(!parsed.pagination_complete);
}

#[test]
fn files_list_request_serializes_force_refresh_default() {
    let request = ReviewsFilesListRequest {
        pull_request_id: "PR_1".into(),
        force_refresh: false,
    };
    let json = serde_json::to_value(&request).expect("serialize");
    assert_eq!(json["pull_request_id"], "PR_1");
    assert_eq!(json["force_refresh"], false);
}

#[test]
fn files_list_response_omits_none_rate_limit() {
    let response = ReviewsFilesListResponse {
        pull_request_id: "PR_1".into(),
        number: None,
        head_ref_oid: "abc".into(),
        head_ref_name: None,
        base_ref_oid: None,
        base_ref_name: None,
        repository_full_name: None,
        viewer_can_mark_viewed: true,
        files: vec![],
        fetched_at: "2026-05-22T10:00:00Z".into(),
        pagination_complete: true,
        rate_limit_snapshot: None,
    };
    let json = serde_json::to_value(&response).expect("serialize");
    assert!(json.get("rate_limit_snapshot").is_none());
}

#[test]
fn files_list_response_back_compat_decode_without_new_fields() {
    // Older daemon responses (or downgraded daemons) don't carry the
    // new head_ref_name / base_ref_oid / base_ref_name /
    // repository_full_name fields. Make sure they still decode and the
    // fields default to None so the patch handler can still take the
    // REST fallback path without crashing.
    let json = r#"{
        "pull_request_id": "PR_1",
        "head_ref_oid": "abc",
        "viewer_can_mark_viewed": true,
        "files": [],
        "fetched_at": "2026-05-22T10:00:00Z",
        "pagination_complete": true
    }"#;
    let parsed: ReviewsFilesListResponse = serde_json::from_str(json).expect("deserialize");
    assert_eq!(parsed.head_ref_name, None);
    assert_eq!(parsed.number, None);
    assert_eq!(parsed.base_ref_oid, None);
    assert_eq!(parsed.base_ref_name, None);
    assert_eq!(parsed.repository_full_name, None);
}
