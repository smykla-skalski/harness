pub mod commands;
pub mod rules;
pub mod validate;
pub mod workflow;

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::workspace::{session_context_dir, utc_now};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty};
use crate::rules::skill_dirs;
/// Active authoring session state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthoringSession {
    pub repo_root: String,
    pub feature: String,
    pub mode: String,
    pub suite_name: String,
    pub suite_dir: String,
    pub updated_at: String,
}

impl AuthoringSession {
    #[must_use]
    pub fn suite_path(&self) -> PathBuf {
        PathBuf::from(&self.suite_dir).join("suite.md")
    }
}

/// File inventory payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileInventory {
    pub scoped_files: Vec<String>,
}

/// A coverage group.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CoverageGroup {
    pub group_id: String,
    pub title: String,
    #[serde(default)]
    pub has_material: bool,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub source_files: Vec<String>,
}

/// Coverage summary result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CoverageSummary {
    pub summary: String,
    #[serde(default)]
    pub groups: Vec<CoverageGroup>,
}

/// A variant signal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VariantSignal {
    pub signal_id: String,
    pub strength: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub source_files: Vec<String>,
    #[serde(default)]
    pub suggested_groups: Vec<String>,
}

/// Variant summary result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VariantSummary {
    pub summary: String,
    #[serde(default)]
    pub signals: Vec<VariantSignal>,
}

/// A schema fact.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SchemaFact {
    pub resource: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub source_files: Vec<String>,
    #[serde(default)]
    pub required_fields: Vec<String>,
}

/// Schema summary result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SchemaSummary {
    pub summary: String,
    #[serde(default)]
    pub facts: Vec<SchemaFact>,
}

/// A proposal group.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProposalGroup {
    pub group_id: String,
    pub title: String,
    #[serde(default)]
    pub included: bool,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub source_refs: Vec<String>,
}

/// Proposal summary result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProposalSummary {
    pub summary: String,
    #[serde(default)]
    pub suite_name: Option<String>,
    #[serde(default)]
    pub suite_dir: Option<String>,
    #[serde(default)]
    pub run_command: Option<String>,
    #[serde(default)]
    pub groups: Vec<ProposalGroup>,
    #[serde(default)]
    pub requires: Vec<String>,
    #[serde(default)]
    pub skipped_groups: Vec<String>,
}

impl ProposalSummary {
    #[must_use]
    pub fn effective_requires(&self) -> Vec<String> {
        self.requires.clone()
    }
}

/// Draft edit request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DraftEditRequest {
    pub summary: String,
    #[serde(default)]
    pub targets: Vec<String>,
}

fn session_file_path() -> Result<PathBuf, CliError> {
    Ok(authoring_workspace_dir()?.join("session.json"))
}

/// Load the current authoring session from disk.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn load_authoring_session() -> Result<Option<AuthoringSession>, CliError> {
    let path = session_file_path()?;
    if !path.exists() {
        return Ok(None);
    }
    let session: AuthoringSession = read_json_typed(&path).map_err(|e| {
        CliErrorKind::authoring_payload_invalid("session", "parse failed")
            .with_details(e.to_string())
    })?;
    Ok(Some(session))
}

/// Save an authoring session to disk.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn save_authoring_session(session: &AuthoringSession) -> Result<AuthoringSession, CliError> {
    let path = session_file_path()?;
    write_json_pretty(&path, session).map_err(|e| {
        CliErrorKind::authoring_payload_invalid("session", "write failed")
            .with_details(e.to_string())
    })?;
    Ok(session.clone())
}

/// Require an active authoring session.
///
/// # Errors
/// Returns `CliError` if no session is active.
pub fn require_authoring_session() -> Result<AuthoringSession, CliError> {
    let session = load_authoring_session()?;
    session.ok_or_else(|| CliErrorKind::AuthoringSessionMissing.into())
}

/// Begin a new authoring session.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn begin_authoring_session(
    repo_root: &Path,
    feature: &str,
    mode: &str,
    suite_dir: &Path,
    suite_name: &str,
) -> Result<AuthoringSession, CliError> {
    if suite_dir.join("suite.md").exists() {
        return Err(
            CliErrorKind::authoring_suite_dir_exists(suite_dir.display().to_string()).into(),
        );
    }
    let session = AuthoringSession {
        repo_root: repo_root
            .canonicalize()
            .unwrap_or_else(|_| repo_root.to_path_buf())
            .to_string_lossy()
            .to_string(),
        feature: feature.to_string(),
        mode: mode.to_string(),
        suite_name: suite_name.to_string(),
        suite_dir: suite_dir
            .canonicalize()
            .unwrap_or_else(|_| suite_dir.to_path_buf())
            .to_string_lossy()
            .to_string(),
        updated_at: utc_now(),
    };
    save_authoring_session(&session)
}

/// Workspace directory for authoring artifacts.
///
/// # Errors
/// Returns `CliError` if the session context directory cannot be determined.
pub fn authoring_workspace_dir() -> Result<PathBuf, CliError> {
    Ok(session_context_dir()?.join(skill_dirs::NEW_WORKSPACE))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

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

    // All env-dependent authoring tests are combined into one test to avoid
    // races on global env vars when cargo runs tests in parallel.
    #[test]
    #[allow(clippy::too_many_lines)]
    fn env_dependent_authoring_tests() {
        // -- save_and_load_session_round_trip --
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

        // -- require_session_errors_when_missing --
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

        // -- begin_session_creates_and_persists --
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

        // -- begin_session_rejects_existing_suite_dir --
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

        // -- authoring_workspace_dir_under_context --
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
