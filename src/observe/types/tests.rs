use super::*;
use crate::kernel::tooling::legacy_tool_context;

fn sample_issue() -> Issue {
    Issue {
        id: "abc123def456".into(),
        line: 42,
        code: IssueCode::BuildOrLintFailure,
        category: IssueCategory::BuildError,
        severity: IssueSeverity::Critical,
        confidence: Confidence::High,
        fix_safety: FixSafety::AutoFixSafe,
        summary: "Build failed".into(),
        details: "error[E0308]".into(),
        fingerprint: "build_or_lint_failure".into(),
        source_role: MessageRole::Assistant,
        source_tool: None,
        fix_target: Some("src/main.rs".into()),
        fix_hint: None,
        evidence_excerpt: None,
    }
}

fn assert_issue_json_identity(json: &str) {
    assert!(json.contains("\"build_error\""));
    assert!(json.contains("\"critical\""));
    assert!(json.contains("\"assistant\""));
    assert!(json.contains("\"abc123def456\""));
}

fn assert_issue_json_optionals_omitted(json: &str) {
    assert!(!json.contains("fix_hint"));
    assert!(!json.contains("source_tool"));
    assert!(!json.contains("evidence_excerpt"));
}

fn assert_scan_state_collections_empty(state: &ScanState) {
    assert!(state.last_tool_uses.is_empty());
    assert!(state.edit_counts.is_empty());
    assert!(state.seen_issues.is_empty());
    assert!(state.issue_occurrences.is_empty());
    assert!(state.pending_resource_creates.is_empty());
    assert!(state.kubectl_query_targets.is_empty());
}

fn assert_scan_state_flags_default(state: &ScanState) {
    assert!(state.session_start_timestamp.is_none());
    assert!(!state.source_code_edited_without_commit);
    assert!(!state.seen_capture_since_last_group_report);
    assert!(!state.seen_any_group_report);
}

fn assert_observer_state_identity(state: &ObserverState) {
    assert_eq!(state.schema_version, ObserverState::CURRENT_VERSION);
    assert_eq!(state.state_version, 0);
    assert_eq!(state.session_id, "test-session");
    assert_eq!(state.cursor, 0);
}

fn assert_observer_state_collections_empty(state: &ObserverState) {
    assert!(state.open_issues.is_empty());
    assert!(state.resolved_issue_ids.is_empty());
    assert!(state.muted_codes.is_empty());
    assert!(state.cycle_history.is_empty());
}

#[test]
fn severity_ordering() {
    assert!(IssueSeverity::Low < IssueSeverity::Medium);
    assert!(IssueSeverity::Medium < IssueSeverity::Critical);
}

#[test]
fn category_display_roundtrip() {
    for cat in IssueCategory::ALL {
        let label = cat.to_string();
        let parsed = IssueCategory::from_label(&label);
        assert_eq!(parsed, Some(*cat), "roundtrip failed for {label}");
    }
}

#[test]
fn severity_display_roundtrip() {
    for sev in [
        IssueSeverity::Low,
        IssueSeverity::Medium,
        IssueSeverity::Critical,
    ] {
        let label = sev.to_string();
        let parsed = IssueSeverity::from_label(&label);
        assert_eq!(parsed, Some(sev), "roundtrip failed for {label}");
    }
}

#[test]
fn issue_serializes_to_json() {
    let json = serde_json::to_string(&sample_issue()).unwrap();
    assert_issue_json_identity(&json);
    assert_issue_json_optionals_omitted(&json);
}

#[test]
fn scan_state_defaults_empty() {
    let state = ScanState::default();
    assert_scan_state_collections_empty(&state);
    assert_scan_state_flags_default(&state);
}

#[test]
fn tool_use_window_evicts_oldest_entry() {
    let mut window = ToolUseWindow::default();
    for index in 0..=ToolUseWindow::LIMIT {
        window.insert(
            format!("tool-{index}"),
            ToolUseRecord {
                tool: legacy_tool_context(
                    "Bash",
                    serde_json::json!({"command": "echo hello"}),
                    None,
                ),
            },
        );
    }

    assert_eq!(window.len(), ToolUseWindow::LIMIT);
    assert!(!window.contains_key("tool-0"));
    assert!(window.contains_key(&format!("tool-{}", ToolUseWindow::LIMIT)));
}

#[test]
fn message_role_display_roundtrip() {
    for role in [MessageRole::User, MessageRole::Assistant] {
        let label = role.to_string();
        let parsed = MessageRole::from_label(&label);
        assert_eq!(parsed, Some(role), "roundtrip failed for {label}");
    }
}

#[test]
fn message_role_human_alias() {
    assert_eq!(MessageRole::from_label("human"), Some(MessageRole::User));
}

#[test]
fn source_tool_display_roundtrip() {
    let tools = [
        SourceTool::Bash,
        SourceTool::Read,
        SourceTool::Write,
        SourceTool::Edit,
        SourceTool::Agent,
        SourceTool::AskUserQuestion,
    ];
    for tool in tools {
        let label = tool.to_string();
        let parsed = SourceTool::from_label(&label);
        assert_eq!(parsed, Some(tool), "roundtrip failed for {label}");
    }
}

#[test]
fn source_tool_unknown_returns_none() {
    assert_eq!(SourceTool::from_label("Unknown"), None);
}

#[test]
fn category_count() {
    assert_eq!(IssueCategory::ALL.len(), 12);
}

#[test]
fn confidence_display_roundtrip() {
    for conf in [Confidence::High, Confidence::Medium, Confidence::Low] {
        let label = conf.to_string();
        let parsed = Confidence::from_label(&label);
        assert_eq!(parsed, Some(conf), "roundtrip failed for {label}");
    }
}

#[test]
fn fix_safety_display_roundtrip() {
    for safety in [
        FixSafety::AutoFixSafe,
        FixSafety::AutoFixGuarded,
        FixSafety::TriageRequired,
        FixSafety::AdvisoryOnly,
    ] {
        let label = safety.to_string();
        let parsed = FixSafety::from_label(&label);
        assert_eq!(parsed, Some(safety), "roundtrip failed for {label}");
    }
}

#[test]
fn fix_safety_is_fixable() {
    assert!(FixSafety::AutoFixSafe.is_fixable());
    assert!(FixSafety::AutoFixGuarded.is_fixable());
    assert!(!FixSafety::TriageRequired.is_fixable());
    assert!(!FixSafety::AdvisoryOnly.is_fixable());
}

#[test]
fn focus_preset_roundtrip() {
    for (label, expected) in [
        ("harness", FocusPreset::Harness),
        ("skills", FocusPreset::Skills),
        ("all", FocusPreset::All),
    ] {
        assert_eq!(FocusPreset::from_label(label), Some(expected));
    }
    assert_eq!(FocusPreset::from_label("unknown"), None);
}

#[test]
fn focus_preset_categories() {
    assert!(FocusPreset::Harness.categories().is_some());
    assert!(FocusPreset::Skills.categories().is_some());
    assert!(FocusPreset::All.categories().is_none());

    let harness = FocusPreset::Harness.categories().unwrap();
    assert!(harness.contains(&IssueCategory::BuildError));
    assert!(!harness.contains(&IssueCategory::SkillBehavior));
}

#[test]
fn issue_code_display_roundtrip() {
    for code in IssueCode::ALL {
        let label = code.to_string();
        let parsed = IssueCode::from_label(&label);
        assert_eq!(parsed, Some(*code), "roundtrip failed for {label}");
    }
}

#[test]
fn issue_code_all_count() {
    assert_eq!(IssueCode::ALL.len(), 62);
}

#[test]
fn compute_issue_id_deterministic() {
    let id1 = compute_issue_id(IssueCode::BuildOrLintFailure, "build_or_lint_failure");
    let id2 = compute_issue_id(IssueCode::BuildOrLintFailure, "build_or_lint_failure");
    assert_eq!(id1, id2);
    assert_eq!(id1.len(), 12);
}

#[test]
fn compute_issue_id_differs_by_code() {
    let id1 = compute_issue_id(IssueCode::BuildOrLintFailure, "test");
    let id2 = compute_issue_id(IssueCode::HookDeniedToolCall, "test");
    assert_ne!(id1, id2);
}

#[test]
fn observer_state_default_for_session() {
    let state = ObserverState::default_for_session("test-session");
    assert_observer_state_identity(&state);
    assert_observer_state_collections_empty(&state);
}

#[test]
fn observer_state_serde_roundtrip() {
    let state = ObserverState::default_for_session("roundtrip-test");
    let json = serde_json::to_string(&state).unwrap();
    let restored: ObserverState = serde_json::from_str(&json).unwrap();
    assert_eq!(restored.session_id, "roundtrip-test");
    assert_eq!(restored.schema_version, state.schema_version);
}

#[test]
fn focus_presets_static() {
    assert_eq!(FOCUS_PRESETS.len(), 3);
    assert_eq!(FOCUS_PRESETS[0].name, "harness");
    assert_eq!(FOCUS_PRESETS[1].name, "skills");
    assert_eq!(FOCUS_PRESETS[2].name, "all");
}
