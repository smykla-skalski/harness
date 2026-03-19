pub mod application;
pub mod commands;
mod payload;
pub mod rules;
mod session;
pub mod validate;
pub mod workflow;

pub use application::{AuthoringApplication, AuthoringPayloadView};
pub use payload::{
    CoverageGroup, CoverageSummary, DraftEditRequest, FileInventory, ProposalGroup,
    ProposalSummary, SchemaFact, SchemaSummary, VariantSignal, VariantSummary,
};
pub use session::{
    AuthoringSession, authoring_workspace_dir, begin_authoring_session, load_authoring_session,
    require_authoring_session, save_authoring_session,
};

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::PathBuf;

    use super::*;

    #[test]
    fn suite_path_joins_suite_md() {
        let session = AuthoringSession {
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
    fn authoring_session_serialization_round_trip() {
        let session = AuthoringSession {
            repo_root: "/repo".to_string(),
            feature: "mesh".to_string(),
            mode: "interactive".to_string(),
            suite_name: "install".to_string(),
            suite_dir: "/repo/suites/install".to_string(),
            updated_at: "2026-03-13T10:00:00Z".to_string(),
        };
        let json = serde_json::to_string(&session).unwrap();
        let deserialized: AuthoringSession = serde_json::from_str(&json).unwrap();
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
        let req = DraftEditRequest {
            summary: "edit".to_string(),
            targets: vec!["suite.md".to_string()],
        };
        let json = serde_json::to_string(&req).unwrap();
        let deserialized: DraftEditRequest = serde_json::from_str(&json).unwrap();
        assert_eq!(req, deserialized);
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn env_dependent_authoring_tests() {
        {
            let dir = tempfile::tempdir().unwrap();
            let xdg = dir.path().join("xdg");
            temp_env::with_vars(
                [
                    ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
                    ("CLAUDE_SESSION_ID", Some("authoring-unit-test")),
                ],
                || {
                    let session = AuthoringSession {
                        repo_root: "/repo".to_string(),
                        feature: "mesh".to_string(),
                        mode: "interactive".to_string(),
                        suite_name: "install".to_string(),
                        suite_dir: "/repo/suites/install".to_string(),
                        updated_at: "2026-03-13T10:00:00Z".to_string(),
                    };

                    let saved = save_authoring_session(&session).unwrap();
                    assert_eq!(saved, session);

                    let loaded = load_authoring_session().unwrap();
                    assert!(loaded.is_some());
                    assert_eq!(loaded.unwrap(), session);
                },
            );
        }

        {
            let dir = tempfile::tempdir().unwrap();
            let xdg = dir.path().join("empty-xdg");
            temp_env::with_vars(
                [
                    ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
                    ("CLAUDE_SESSION_ID", Some("authoring-require-test")),
                ],
                || {
                    let result = require_authoring_session();
                    assert!(result.is_err());
                    let err = result.unwrap_err();
                    assert_eq!(err.code(), "KSRCLI040");
                },
            );
        }

        {
            let dir = tempfile::tempdir().unwrap();
            let xdg = dir.path().join("begin-xdg");
            temp_env::with_vars(
                [
                    ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
                    ("CLAUDE_SESSION_ID", Some("authoring-begin-test")),
                ],
                || {
                    let repo = dir.path().join("repo");
                    fs::create_dir_all(&repo).unwrap();
                    let suite_dir = dir.path().join("suite");
                    fs::create_dir_all(&suite_dir).unwrap();

                    let session = begin_authoring_session(
                        &repo,
                        "mesh",
                        "interactive",
                        &suite_dir,
                        "install",
                    )
                    .unwrap();

                    assert_eq!(session.feature, "mesh");
                    assert_eq!(session.mode, "interactive");
                    assert_eq!(session.suite_name, "install");

                    let loaded = load_authoring_session().unwrap().unwrap();
                    assert_eq!(loaded.feature, "mesh");
                },
            );
        }

        {
            let dir = tempfile::tempdir().unwrap();
            let xdg = dir.path().join("exists-xdg");
            temp_env::with_vars(
                [
                    ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
                    ("CLAUDE_SESSION_ID", Some("authoring-exists-test")),
                ],
                || {
                    let repo = dir.path().join("repo");
                    fs::create_dir_all(&repo).unwrap();
                    let suite_dir = dir.path().join("existing-suite");
                    fs::create_dir_all(&suite_dir).unwrap();
                    fs::write(suite_dir.join("suite.md"), "# existing suite").unwrap();

                    let result = begin_authoring_session(
                        &repo,
                        "mesh",
                        "interactive",
                        &suite_dir,
                        "install",
                    );

                    assert!(result.is_err());
                    let err = result.unwrap_err();
                    assert_eq!(err.code(), "KSRCLI062");
                },
            );
        }

        {
            temp_env::with_vars([("CLAUDE_SESSION_ID", Some("workspace-dir-test"))], || {
                let workspace = authoring_workspace_dir().unwrap();
                let name = workspace
                    .file_name()
                    .unwrap()
                    .to_string_lossy()
                    .into_owned();
                assert_eq!(name, "suite-new");
            });
        }
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
}
