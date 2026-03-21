use super::*;

#[test]
fn skill_name_short_does_not_fire() {
    // Short names (new, run, observe) are the correct convention in SKILL.md
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Write",
        "input": {
            "file_path": "/data/.claude/skills/observe/SKILL.md",
            "content": "---\nname: observe\n---\nSome content"
        }
    });
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::ShortSkillNameInSkillFile),
        "short name 'observe' should not trigger ShortSkillNameInSkillFile"
    );
}

#[test]
fn skill_name_colon_prefixed_fires() {
    // Colon-prefixed names (suite:create) are wrong in SKILL.md files
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Write",
        "input": {
            "file_path": "/data/.claude/skills/create/SKILL.md",
            "content": "---\nname: suite:create\n---\nSome content"
        }
    });
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.code == IssueCode::ShortSkillNameInSkillFile),
        "colon-prefixed 'suite:create' should trigger ShortSkillNameInSkillFile"
    );
    let issue = issues
        .iter()
        .find(|i| i.code == IssueCode::ShortSkillNameInSkillFile)
        .unwrap();
    assert!(issue.summary.contains("suite:create"));
}

#[test]
fn golden_json_output_all_fields() {
    // Construct issue with all fields, verify render_json includes everything
    let mut state = make_state();
    let issues = check_text_for_issues(
        42,
        MessageRole::User,
        "error[E0308]: mismatched types\n  expected u32, found &str",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(!issues.is_empty());
    let issue = &issues[0];
    let rendered = output::render_json(issue);
    let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();

    assert_output_json_identity_fields(&parsed);
    assert_output_json_classification_fields(&parsed);
    assert_output_json_message_fields(&parsed);

    let id = parsed["id"].as_str().unwrap();
    assert_eq!(id.len(), 12);
    assert!(id.chars().all(|c| c.is_ascii_hexdigit()));
}

#[test]
fn confidence_propagation_from_rules() {
    let mut state = make_state();
    // Build error -> High confidence
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "error[E0308]: mismatched types\n  expected u32",
        Some(SourceTool::Bash),
        &mut state,
    );
    let build_issue = issues
        .iter()
        .find(|i| i.code == IssueCode::BuildOrLintFailure);
    assert!(build_issue.is_some());
    assert_eq!(build_issue.unwrap().confidence, Confidence::High);
}

#[test]
fn fix_safety_backward_compat() {
    // AutoFixSafe -> fixable: true
    // TriageRequired -> fixable: false
    // AdvisoryOnly -> fixable: false
    // AutoFixGuarded -> fixable: true
    for (safety, expected) in [
        (FixSafety::AutoFixSafe, true),
        (FixSafety::AutoFixGuarded, true),
        (FixSafety::TriageRequired, false),
        (FixSafety::AdvisoryOnly, false),
    ] {
        assert_eq!(
            safety.is_fixable(),
            expected,
            "{safety} should have fixable={expected}"
        );
    }
}

#[test]
fn dedup_tracking_occurrence_count() {
    let mut state = make_state();
    // Feed same text twice -> should only get 1 issue but occurrence_count=2
    check_text_for_issues(
        10,
        MessageRole::User,
        "The system denied this tool call because it violates policy",
        None,
        &mut state,
    );
    check_text_for_issues(
        20,
        MessageRole::User,
        "The system denied this tool call because it violates policy",
        None,
        &mut state,
    );

    // Only 1 unique issue in seen_issues
    let hook_denial_count = state
        .seen_issues
        .iter()
        .filter(|(code, _)| *code == IssueCode::HookDeniedToolCall)
        .count();
    assert_eq!(hook_denial_count, 1);

    // But occurrence tracker has count=2
    let tracker = state
        .issue_occurrences
        .iter()
        .find(|((code, _), _)| *code == IssueCode::HookDeniedToolCall);
    assert!(tracker.is_some());
    let (_, tracker) = tracker.unwrap();
    assert_eq!(tracker.count, 2);
    assert_eq!(tracker.last_seen_line, 20);
}

#[test]
fn focus_preset_filtering() {
    let harness_cats = FocusPreset::Harness.categories().unwrap();
    let skills_cats = FocusPreset::Skills.categories().unwrap();

    // BuildError is in harness, not skills
    assert!(harness_cats.contains(&IssueCategory::BuildError));
    assert!(!skills_cats.contains(&IssueCategory::BuildError));

    // SkillBehavior is in skills, not harness
    assert!(skills_cats.contains(&IssueCategory::SkillBehavior));
    assert!(!harness_cats.contains(&IssueCategory::SkillBehavior));

    // All returns None (no filter)
    assert!(FocusPreset::All.categories().is_none());
}

#[test]
fn source_tool_in_json_output() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "error[E0308]: mismatched types\n  expected u32",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(!issues.is_empty());
    let issue = &issues[0];
    assert_eq!(issue.source_tool, Some(SourceTool::Bash));

    let rendered = output::render_json(issue);
    let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
    assert_eq!(parsed["source"]["tool"], "Bash");
}

#[test]
fn source_tool_absent_in_json_when_none() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "The system denied this tool call because it violates policy",
        None,
        &mut state,
    );
    assert!(!issues.is_empty());
    let rendered = output::render_json(&issues[0]);
    let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
    assert!(parsed["source"].get("tool").is_none());
}

#[test]
fn tool_correlation_window_pruning() {
    let mut state = make_state();
    // Add 150 tool uses
    for i in 0..150 {
        let block = serde_json::json!({
            "type": "tool_use",
            "id": format!("tool_{i}"),
            "name": "Read",
            "input": {"file_path": format!("/tmp/file_{i}.rs")}
        });
        check_tool_use_for_issues(i, &block, &mut state);
    }
    // Should be capped at ~100
    assert!(
        state.last_tool_uses.len() <= 101,
        "tool uses should be pruned to ~100, got {}",
        state.last_tool_uses.len()
    );
}

// ─── Repository layout drift tests (Phase 7.5) ────────────────────

#[test]
fn fix_target_paths_look_valid() {
    // Collect all fix_target strings from TEXT_RULES and verify they
    // look like relative paths (not stale like "cli.rs" without src/)
    use crate::observe::classifier::rules::TEXT_RULES;
    for rule in TEXT_RULES {
        if let super::rules::RuleGuidance::Fix {
            target: Some(target),
            ..
        } = rule.guidance
        {
            // Targets should either contain a slash or be a known pattern
            assert!(
                target.contains('/') || target.contains('.'),
                "fix_target '{target}' for {:?} looks incomplete - should include path segments",
                rule.code
            );
        }
    }
}

#[test]
fn registry_and_all_codes_aligned() {
    // Every code in IssueCode::ALL should have a registry entry
    use crate::observe::classifier::registry::issue_code_meta;
    for code in IssueCode::ALL {
        assert!(
            issue_code_meta(*code).is_some(),
            "IssueCode::{code} missing from registry"
        );
    }
}

// ─── Fixture-driven scan test (Phase 7.6) ──────────────────────────

#[test]
fn scan_fixture_finds_known_issues() {
    // Synthetic JSONL with a known build error
    let session_line = r#"{"timestamp":"2026-03-15T10:00:00Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"error[E0308]: mismatched types\n  expected u32, found &str"}]}}"#;
    let mut state = ScanState::default();
    // Seed a tool_use record so the tool_result resolves to Bash
    state.last_tool_uses.insert(
        "t1".to_string(),
        ToolUseRecord {
            tool: legacy_tool_context("Bash", serde_json::json!({"command": "cargo check"}), None),
        },
    );
    let issues = super::classify_line(0, session_line, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::BuildError),
        "should detect build error in fixture"
    );
}

#[test]
fn evidence_excerpt_populated_for_long_details() {
    let mut state = make_state();
    let long_text = format!(
        "error[E0308]: mismatched types\n  expected u32, found &str\n{}",
        "x".repeat(200)
    );
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        &long_text,
        Some(SourceTool::Bash),
        &mut state,
    );
    let build = issues
        .iter()
        .find(|i| i.category == IssueCategory::BuildError);
    assert!(build.is_some());
    let excerpt = &build.unwrap().evidence_excerpt;
    assert!(
        excerpt.is_some(),
        "evidence_excerpt should be populated for long details"
    );
    assert!(excerpt.as_ref().unwrap().len() <= 200);
}

#[test]
fn detects_uncommitted_source_edit_before_second_edit() {
    let mut state = make_state();
    // First edit: sets the flag
    let edit1 = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Edit",
        "input": { "file_path": "/repo/pkg/xds/proxy.go", "old_string": "a", "new_string": "b" }
    });
    let issues = check_tool_use_for_issues(10, &edit1, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::UncommittedSourceCodeEdit),
        "first edit should not trigger"
    );
    assert!(state.source_code_edited_without_commit);

    // Second edit without commit: should fire
    let edit2 = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Write",
        "input": { "file_path": "/repo/pkg/xds/proxy.go", "content": "new content" }
    });
    let issues = check_tool_use_for_issues(20, &edit2, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.code == IssueCode::UncommittedSourceCodeEdit
                && i.category == IssueCategory::SkillBehavior
                && i.severity == IssueSeverity::Medium)
    );
}

#[test]
fn detects_uncommitted_source_edit_before_harness_command() {
    let mut state = make_state();
    let edit = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Edit",
        "input": { "file_path": "/repo/pkg/xds/proxy.go", "old_string": "a", "new_string": "b" }
    });
    check_tool_use_for_issues(10, &edit, &mut state);

    let bash = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness apply --manifest g01/01.yaml" }
    });
    let issues = check_tool_use_for_issues(20, &bash, &mut state);
    assert!(issues.iter().any(
        |i| i.code == IssueCode::UncommittedSourceCodeEdit && i.summary.contains("uncommitted")
    ));
}

#[test]
fn git_commit_clears_uncommitted_source_flag() {
    let mut state = make_state();
    let edit = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Edit",
        "input": { "file_path": "/repo/pkg/xds/proxy.go", "old_string": "a", "new_string": "b" }
    });
    check_tool_use_for_issues(10, &edit, &mut state);
    assert!(state.source_code_edited_without_commit);

    let commit = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "git add pkg/xds/proxy.go && git commit -m 'fix: proxy config'" }
    });
    let issues = check_tool_use_for_issues(20, &commit, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::UncommittedSourceCodeEdit),
        "git commit should not trigger uncommitted edit issue"
    );
    assert!(!state.source_code_edited_without_commit);
}

#[test]
fn skips_uncommitted_detection_for_non_source_files() {
    let mut state = make_state();
    let edit = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Write",
        "input": { "file_path": "/repo/docs/README.md", "content": "# docs" }
    });
    check_tool_use_for_issues(10, &edit, &mut state);
    assert!(!state.source_code_edited_without_commit);
}

#[test]
fn uncommitted_edit_detects_various_source_extensions() {
    for extension in &["go", "rs", "py", "ts", "java", "c", "cpp", "rb", "sh"] {
        let mut state = make_state();
        let path = format!("/repo/src/main.{extension}");
        let edit = serde_json::json!({
            "type": "tool_use",
            "id": "t1",
            "name": "Edit",
            "input": { "file_path": path, "old_string": "a", "new_string": "b" }
        });
        check_tool_use_for_issues(10, &edit, &mut state);
        assert!(
            state.source_code_edited_without_commit,
            "should track .{extension} files"
        );
    }
}
