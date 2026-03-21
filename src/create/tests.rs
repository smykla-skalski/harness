use std::fs;
use std::path::PathBuf;

use super::*;

#[test]
fn suite_path_joins_suite_md() {
    let session = CreateSession {
        repo_root: "/repo".to_string(),
        feature: "mesh".to_string(),
        mode: "interactive".to_string(),
        suite_name: "install".to_string(),
        suite_dir: "/repo/suites/install".to_string(),
        updated_at: "2026-03-13T10:00:00Z".to_string(),
    };
    assert_eq!(
        session.suite_path(),
        PathBuf::from("/repo/suites/install/suite.md")
    );
}

#[test]
fn create_session_serialization_round_trip() {
    let session = CreateSession {
        repo_root: "/repo".to_string(),
        feature: "mesh".to_string(),
        mode: "interactive".to_string(),
        suite_name: "install".to_string(),
        suite_dir: "/repo/suites/install".to_string(),
        updated_at: "2026-03-13T10:00:00Z".to_string(),
    };
    let json = serde_json::to_string(&session).unwrap();
    let deserialized: CreateSession = serde_json::from_str(&json).unwrap();
    assert_eq!(session, deserialized);
}

#[test]
fn file_inventory_serialization() {
    let inv = FileInventory {
        scoped_files: vec!["suite.md".to_string(), "groups/g01.md".to_string()],
    };
    let json = serde_json::to_string(&inv).unwrap();
    let deserialized: FileInventory = serde_json::from_str(&json).unwrap();
    assert_eq!(inv, deserialized);
}

#[test]
fn coverage_summary_serialization() {
    let summary = CoverageSummary {
        summary: "coverage".to_string(),
        groups: vec![CoverageGroup {
            group_id: "g01".to_string(),
            title: "Install".to_string(),
            has_material: true,
            description: Some("Covers installation.".to_string()),
            source_files: vec!["docs/install.md".to_string()],
        }],
    };
    let json = serde_json::to_string(&summary).unwrap();
    let deserialized: CoverageSummary = serde_json::from_str(&json).unwrap();
    assert_eq!(summary, deserialized);
}

#[test]
fn draft_edit_request_serialization() {
    let request = DraftEditRequest {
        summary: "edit".to_string(),
        targets: vec!["suite.md".to_string()],
    };
    let json = serde_json::to_string(&request).unwrap();
    let deserialized: DraftEditRequest = serde_json::from_str(&json).unwrap();
    assert_eq!(request, deserialized);
}

#[test]
fn create_session_persistence_under_xdg() {
    let dir = tempfile::tempdir().unwrap();
    let xdg = dir.path().join("xdg");
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("create-unit-test")),
        ],
        || {
            let session = CreateSession {
                repo_root: "/repo".to_string(),
                feature: "mesh".to_string(),
                mode: "interactive".to_string(),
                suite_name: "install".to_string(),
                suite_dir: "/repo/suites/install".to_string(),
                updated_at: "2026-03-13T10:00:00Z".to_string(),
            };

            let saved = save_create_session(&session).unwrap();
            assert_eq!(saved, session);

            let loaded = load_create_session().unwrap();
            assert!(loaded.is_some());
            assert_eq!(loaded.unwrap(), session);
        },
    );
}

#[test]
fn require_create_session_fails_without_saved_session() {
    let dir = tempfile::tempdir().unwrap();
    let xdg = dir.path().join("empty-xdg");
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("create-require-test")),
        ],
        || {
            let result = require_create_session();
            assert!(result.is_err());
            let error = result.unwrap_err();
            assert_eq!(error.code(), "KSRCLI040");
        },
    );
}

#[test]
fn begin_create_session_persists_new_session() {
    let dir = tempfile::tempdir().unwrap();
    let xdg = dir.path().join("begin-xdg");
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("create-begin-test")),
        ],
        || {
            let repo = dir.path().join("repo");
            fs::create_dir_all(&repo).unwrap();
            let suite_dir = dir.path().join("suite");
            fs::create_dir_all(&suite_dir).unwrap();

            let session =
                begin_create_session(&repo, "mesh", "interactive", &suite_dir, "install").unwrap();

            assert_eq!(session.feature, "mesh");
            assert_eq!(session.mode, "interactive");
            assert_eq!(session.suite_name, "install");

            let loaded = load_create_session().unwrap().unwrap();
            assert_eq!(loaded.feature, "mesh");
        },
    );
}

#[test]
fn begin_create_session_rejects_existing_suite() {
    let dir = tempfile::tempdir().unwrap();
    let xdg = dir.path().join("exists-xdg");
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("create-exists-test")),
        ],
        || {
            let repo = dir.path().join("repo");
            fs::create_dir_all(&repo).unwrap();
            let suite_dir = dir.path().join("existing-suite");
            fs::create_dir_all(&suite_dir).unwrap();
            fs::write(suite_dir.join("suite.md"), "# existing suite").unwrap();

            let result = begin_create_session(&repo, "mesh", "interactive", &suite_dir, "install");

            assert!(result.is_err());
            let error = result.unwrap_err();
            assert_eq!(error.code(), "KSRCLI062");
        },
    );
}

#[test]
fn create_workspace_dir_uses_suite_create_name() {
    temp_env::with_vars([("CLAUDE_SESSION_ID", Some("workspace-dir-test"))], || {
        let workspace = create_workspace_dir().unwrap();
        let name = workspace
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        assert_eq!(name, "suite-create");
    });
}

#[test]
fn proposal_summary_deserializes_with_defaults() {
    let json = r#"{"summary": "proposal"}"#;
    let summary: ProposalSummary = serde_json::from_str(json).unwrap();
    assert_eq!(summary.summary, "proposal");
    assert!(summary.groups.is_empty());
    assert!(summary.requires.is_empty());
    assert!(summary.skipped_groups.is_empty());
    assert!(summary.suite_name.is_none());
}

#[test]
fn proposal_summary_effective_requires_returns_requires() {
    let summary = ProposalSummary {
        summary: "proposal".to_string(),
        suite_name: None,
        suite_dir: None,
        run_command: None,
        groups: vec![],
        requires: vec!["docker".to_string(), "helm".to_string()],
        skipped_groups: vec![],
    };

    assert_eq!(
        summary.effective_requires(),
        vec!["docker".to_string(), "helm".to_string()]
    );
}

#[test]
fn variant_summary_serialization() {
    let summary = VariantSummary {
        summary: "variants".to_string(),
        signals: vec![VariantSignal {
            signal_id: "s01".to_string(),
            strength: "strong".to_string(),
            description: Some("desc".to_string()),
            source_files: vec![],
            suggested_groups: vec!["g01".to_string()],
        }],
    };
    let json = serde_json::to_string(&summary).unwrap();
    let deserialized: VariantSummary = serde_json::from_str(&json).unwrap();
    assert_eq!(summary, deserialized);
}

#[test]
fn schema_summary_serialization() {
    let summary = SchemaSummary {
        summary: "schema".to_string(),
        facts: vec![SchemaFact {
            resource: "MeshTrafficPermission".to_string(),
            description: Some("Controls traffic".to_string()),
            source_files: vec!["pkg/mtp.go".to_string()],
            required_fields: vec!["spec.targetRef".to_string()],
        }],
    };
    let json = serde_json::to_string(&summary).unwrap();
    let deserialized: SchemaSummary = serde_json::from_str(&json).unwrap();
    assert_eq!(summary, deserialized);
}
