use std::env;
use std::fmt;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind, cow};
use crate::rules::skill_dirs;
use crate::infra::persistence::VersionedJsonRepository;

/// Author approval mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum ApprovalMode {
    Interactive,
    Bypass,
}

/// Author workflow phases.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum AuthorPhase {
    Discovery,
    PrewriteReview,
    Writing,
    PostwriteReview,
    Complete,
    Cancelled,
}

impl fmt::Display for AuthorPhase {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Discovery => "discovery",
            Self::PrewriteReview => "prewrite_review",
            Self::Writing => "writing",
            Self::PostwriteReview => "postwrite_review",
            Self::Complete => "complete",
            Self::Cancelled => "cancelled",
        })
    }
}

/// Review gate type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[non_exhaustive]
#[serde(rename_all = "snake_case")]
pub enum ReviewGate {
    Prewrite,
    Postwrite,
    Copy,
}

#[non_exhaustive]
/// Answer to a review gate prompt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AuthorAnswer {
    #[serde(rename = "Approve proposal")]
    ApproveProposal,
    #[serde(rename = "Request changes")]
    RequestChanges,
    #[serde(rename = "Cancel")]
    Cancel,
    #[serde(rename = "Approve suite")]
    ApproveSuite,
    #[serde(rename = "Copy command")]
    CopyCommand,
    #[serde(rename = "Skip")]
    Skip,
}

/// Session info within author state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthorSessionInfo {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo_root: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub feature: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suite_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suite_dir: Option<String>,
}

impl AuthorSessionInfo {
    #[must_use]
    pub fn suite_path(&self) -> Option<PathBuf> {
        self.suite_dir.as_ref().map(PathBuf::from)
    }
}

/// Review sub-state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthorReviewState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gate: Option<ReviewGate>,
    #[serde(default)]
    pub awaiting_answer: bool,
    #[serde(default)]
    pub round: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_answer: Option<AuthorAnswer>,
}

/// Draft sub-state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthorDraftState {
    #[serde(default)]
    pub suite_tree_written: bool,
    #[serde(default)]
    pub written_paths: Vec<String>,
}

/// Full author workflow state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthorWorkflowState {
    pub schema_version: u32,
    pub mode: ApprovalMode,
    pub phase: AuthorPhase,
    pub session: AuthorSessionInfo,
    pub review: AuthorReviewState,
    pub draft: AuthorDraftState,
    pub updated_at: String,
    pub transition_count: u32,
    pub last_event: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct AuthorWorkflowPayload {
    pub phase: AuthorPhase,
    pub review: AuthorReviewState,
    pub draft: AuthorDraftState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct AuthorWorkflowStateRecord {
    pub schema_version: u32,
    pub mode: ApprovalMode,
    pub session: AuthorSessionInfo,
    pub state: AuthorWorkflowPayload,
    pub updated_at: String,
    pub transition_count: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_event: Option<String>,
}

impl AuthorWorkflowState {
    #[must_use]
    pub fn new(mode: ApprovalMode, suite_dir: Option<String>, occurred_at: String) -> Self {
        let phase = if mode == ApprovalMode::Bypass {
            AuthorPhase::Writing
        } else {
            AuthorPhase::Discovery
        };
        Self {
            schema_version: AUTHOR_STATE_SCHEMA_VERSION,
            mode,
            phase,
            session: AuthorSessionInfo {
                repo_root: None,
                feature: None,
                suite_name: None,
                suite_dir,
            },
            review: AuthorReviewState {
                gate: None,
                awaiting_answer: false,
                round: 0,
                last_answer: None,
            },
            draft: AuthorDraftState {
                suite_tree_written: false,
                written_paths: vec![],
            },
            updated_at: occurred_at,
            transition_count: 0,
            last_event: Some("ApprovalFlowStarted".to_string()),
        }
    }

    #[must_use]
    pub fn mode(&self) -> ApprovalMode {
        self.mode
    }

    #[must_use]
    pub fn phase(&self) -> AuthorPhase {
        self.phase
    }

    #[must_use]
    pub fn has_written_suite(&self) -> bool {
        self.draft.suite_tree_written
    }

    #[must_use]
    pub fn suite_dir(&self) -> Option<&str> {
        self.session.suite_dir.as_deref()
    }

    #[must_use]
    pub fn suite_path(&self) -> Option<PathBuf> {
        self.session.suite_path()
    }

    fn to_record(&self) -> AuthorWorkflowStateRecord {
        AuthorWorkflowStateRecord {
            schema_version: self.schema_version,
            mode: self.mode,
            session: self.session.clone(),
            state: AuthorWorkflowPayload {
                phase: self.phase,
                review: self.review.clone(),
                draft: self.draft.clone(),
            },
            updated_at: self.updated_at.clone(),
            transition_count: self.transition_count,
            last_event: self.last_event.clone(),
        }
    }

    fn from_record(record: AuthorWorkflowStateRecord) -> Self {
        Self {
            schema_version: record.schema_version,
            mode: record.mode,
            phase: record.state.phase,
            session: record.session,
            review: record.state.review,
            draft: record.state.draft,
            updated_at: record.updated_at,
            transition_count: record.transition_count,
            last_event: record.last_event,
        }
    }
}

impl Serialize for AuthorWorkflowState {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        self.to_record().serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for AuthorWorkflowState {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        AuthorWorkflowStateRecord::deserialize(deserializer).map(Self::from_record)
    }
}

const AUTHOR_STATE_SCHEMA_VERSION: u32 = 2;
const LEGACY_AUTHOR_STATE_FILE: &str = "suite-author-state.json";

/// Path to the author state file.
///
/// # Errors
/// Returns `CliError` if the current directory cannot be determined.
pub fn author_state_path() -> Result<PathBuf, CliError> {
    let cwd = env::current_dir().map_err(|e| -> CliError {
        CliErrorKind::workflow_io(cow!("failed to determine current directory: {e}")).into()
    })?;
    Ok(cwd.join(".harness").join(skill_dirs::NEW_STATE_FILE))
}

fn legacy_author_state_path() -> Result<PathBuf, CliError> {
    let cwd = env::current_dir().map_err(|e| -> CliError {
        CliErrorKind::workflow_io(cow!("failed to determine current directory: {e}")).into()
    })?;
    Ok(cwd.join(".harness").join(LEGACY_AUTHOR_STATE_FILE))
}

fn author_repository() -> Result<VersionedJsonRepository<AuthorWorkflowState>, CliError> {
    Ok(author_repository_for_path(author_state_path()?))
}

fn author_repository_for_path(path: PathBuf) -> VersionedJsonRepository<AuthorWorkflowState> {
    VersionedJsonRepository::new(path, AUTHOR_STATE_SCHEMA_VERSION)
        .with_migrations(vec![Box::new(migrate_author_v1_to_v2)])
}

/// Read author state from disk.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn read_author_state() -> Result<Option<AuthorWorkflowState>, CliError> {
    let path = author_state_path()?;
    if path.exists() {
        return load_author_state_repo(&author_repository()?, &path);
    }

    let legacy_path = legacy_author_state_path()?;
    let loaded = load_author_state_repo(
        &author_repository_for_path(legacy_path.clone()),
        &legacy_path,
    )?;
    if let Some(state) = loaded.as_ref() {
        author_repository()?.save(state)?;
    }
    Ok(loaded)
}

/// Write author state to disk.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn write_author_state(state: &AuthorWorkflowState) -> Result<(), CliError> {
    let repo = author_repository()?;
    repo.save(state)?;
    Ok(())
}

fn load_author_state_repo(
    repo: &VersionedJsonRepository<AuthorWorkflowState>,
    path: &Path,
) -> Result<Option<AuthorWorkflowState>, CliError> {
    match repo.load() {
        Ok(loaded) => Ok(loaded),
        Err(error) if error.code() == "WORKFLOW_VERSION" => Err(CliErrorKind::workflow_version(
            cow!("author state requires schema version 2"),
        )
        .with_details(format!(
            "{}\nDelete {} or re-run `harness authoring approval-begin` to regenerate the author state.",
            error.message(),
            path.display()
        ))),
        Err(error) => Err(error),
    }
}

#[derive(Debug, Deserialize)]
struct AuthorWorkflowStateV1 {
    pub mode: ApprovalMode,
    pub phase: AuthorPhase,
    pub session: AuthorSessionInfo,
    pub review: AuthorReviewState,
    pub draft: AuthorDraftState,
    pub updated_at: String,
    pub transition_count: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_event: Option<String>,
}

fn migrate_author_v1_to_v2(data: Value) -> Result<Value, CliError> {
    let v1: AuthorWorkflowStateV1 = serde_json::from_value(data).map_err(|error| -> CliError {
        CliErrorKind::workflow_parse(cow!("failed to parse author workflow v1: {error}")).into()
    })?;
    let v2 = AuthorWorkflowStateRecord {
        schema_version: AUTHOR_STATE_SCHEMA_VERSION,
        mode: v1.mode,
        session: v1.session,
        state: AuthorWorkflowPayload {
            phase: v1.phase,
            review: v1.review,
            draft: v1.draft,
        },
        updated_at: v1.updated_at,
        transition_count: v1.transition_count,
        last_event: v1.last_event,
    };
    serde_json::to_value(v2).map_err(|error| -> CliError {
        CliErrorKind::workflow_serialize(cow!("failed to serialize author workflow v2: {error}"))
            .into()
    })
}

/// Check if writing is allowed in the current state.
///
/// # Errors
/// Returns a static reason string when writing is not allowed.
pub fn can_write(state: &AuthorWorkflowState) -> Result<(), &'static str> {
    if state.mode() == ApprovalMode::Bypass {
        return Ok(());
    }
    match state.phase() {
        AuthorPhase::Writing => Ok(()),
        AuthorPhase::PrewriteReview => {
            Err("wait for the current pre-write approval answer before writing suite files")
        }
        AuthorPhase::PostwriteReview => {
            Err("wait for the current post-write approval answer before editing the saved suite")
        }
        AuthorPhase::Complete => {
            Err("the saved suite is already approved; request changes before editing it again")
        }
        AuthorPhase::Cancelled => {
            Err("the suite:new flow was cancelled; restart authoring before writing again")
        }
        AuthorPhase::Discovery => {
            Err("suite:new is still collecting context before the first review gate")
        }
    }
}

/// Check if a review gate can be requested.
///
/// # Errors
/// Returns a static reason string when the gate cannot be requested.
pub fn can_request_gate(state: &AuthorWorkflowState, gate: ReviewGate) -> Result<(), &'static str> {
    if state.mode() == ApprovalMode::Bypass {
        return Err("bypass mode forbids canonical review prompts");
    }
    match gate {
        ReviewGate::Prewrite => {
            if state.phase() == AuthorPhase::PrewriteReview {
                Ok(())
            } else {
                Err("pre-write approval can only run while the proposal is still pending")
            }
        }
        ReviewGate::Postwrite => {
            if !state.has_written_suite() {
                return Err("ask post-write approval before stopping after suite writes");
            }
            if state.phase() == AuthorPhase::Writing {
                Ok(())
            } else {
                Err("post-write approval is only valid after initial writes or an edit round")
            }
        }
        ReviewGate::Copy => {
            if state.phase() == AuthorPhase::Complete {
                Ok(())
            } else {
                Err("copy prompt is only valid after the saved suite is approved")
            }
        }
    }
}

/// Check if the author flow can be stopped.
///
/// # Errors
/// Returns a static reason string when stopping is not allowed.
pub fn can_stop(state: &AuthorWorkflowState) -> Result<(), &'static str> {
    if state.mode() == ApprovalMode::Bypass {
        return Ok(());
    }
    match state.phase() {
        AuthorPhase::Writing => Err("ask the post-write approval gate before stopping"),
        AuthorPhase::PostwriteReview => {
            Err("wait for the current post-write approval answer before stopping")
        }
        _ => Ok(()),
    }
}

/// Next action for an author workflow state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthorNextAction {
    ReloadState,
    ContinueBypass,
    ResumeDiscovery,
    ResumePrewriteReview,
    ApplyEditRound,
    ContinueInitialWrite,
    ResumePostwriteReview,
    Stopped,
    OfferCopyGate,
}

impl fmt::Display for AuthorNextAction {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::ReloadState => {
                "Reload the saved suite:new state before continuing."
            }
            Self::ContinueBypass => {
                "Continue suite:new in bypass mode using the saved authoring payloads."
            }
            Self::ResumeDiscovery => {
                "Resume discovery and proposal preparation before reopening review."
            }
            Self::ResumePrewriteReview => {
                "Resume the pre-write review loop and ask the pre-write gate question before writing suite files."
            }
            Self::ApplyEditRound => {
                "Apply the current edit round, then reopen the post-write review gate."
            }
            Self::ContinueInitialWrite => {
                "Continue the initial suite write phase from the saved proposal."
            }
            Self::ResumePostwriteReview => {
                "Resume the post-write review loop and ask the post-write gate question before stopping."
            }
            Self::Stopped => {
                "The suite:new flow was cancelled. Do not write more files unless restarted."
            }
            Self::OfferCopyGate => {
                "The suite is approved. Offer the copy gate or stop the skill."
            }
        })
    }
}

/// Get the next action hint based on author state.
#[must_use]
pub fn next_action(state: Option<&AuthorWorkflowState>) -> AuthorNextAction {
    let Some(state) = state else {
        return AuthorNextAction::ReloadState;
    };
    if state.mode() == ApprovalMode::Bypass {
        return AuthorNextAction::ContinueBypass;
    }
    match state.phase() {
        AuthorPhase::Discovery => AuthorNextAction::ResumeDiscovery,
        AuthorPhase::PrewriteReview => AuthorNextAction::ResumePrewriteReview,
        AuthorPhase::Writing => {
            if state.has_written_suite() {
                AuthorNextAction::ApplyEditRound
            } else {
                AuthorNextAction::ContinueInitialWrite
            }
        }
        AuthorPhase::PostwriteReview => AuthorNextAction::ResumePostwriteReview,
        AuthorPhase::Cancelled => AuthorNextAction::Stopped,
        AuthorPhase::Complete => AuthorNextAction::OfferCopyGate,
    }
}

/// Check if a path is allowed for suite:new writes.
#[must_use]
pub fn suite_author_path_allowed(path: &Path, suite_dir: &Path) -> bool {
    if path == suite_dir.join("suite.md") {
        return true;
    }
    if path.starts_with(suite_dir.join("groups")) {
        return true;
    }
    path.starts_with(suite_dir.join("baseline"))
}

#[cfg(test)]
mod tests {
    use std::fs;

    use serde_json::{Value, json};
    use tempfile::TempDir;

    use super::*;

    fn make_state(phase: AuthorPhase, mode: ApprovalMode) -> AuthorWorkflowState {
        AuthorWorkflowState {
            schema_version: 1,
            mode,
            phase,
            session: AuthorSessionInfo {
                repo_root: None,
                feature: None,
                suite_name: None,
                suite_dir: Some("/tmp/suite".to_string()),
            },
            review: AuthorReviewState {
                gate: None,
                awaiting_answer: false,
                round: 0,
                last_answer: None,
            },
            draft: AuthorDraftState {
                suite_tree_written: false,
                written_paths: vec![],
            },
            updated_at: "2025-01-01T00:00:00Z".to_string(),
            transition_count: 0,
            last_event: None,
        }
    }

    #[test]
    fn author_phase_display() {
        let cases = [
            (AuthorPhase::Discovery, "discovery"),
            (AuthorPhase::PrewriteReview, "prewrite_review"),
            (AuthorPhase::Writing, "writing"),
            (AuthorPhase::PostwriteReview, "postwrite_review"),
            (AuthorPhase::Complete, "complete"),
            (AuthorPhase::Cancelled, "cancelled"),
        ];
        for (variant, expected) in cases {
            assert_eq!(variant.to_string(), expected);
        }
    }

    #[test]
    fn approval_mode_serialization() {
        let json = serde_json::to_value(ApprovalMode::Interactive).unwrap();
        assert_eq!(json, "interactive");
        let json = serde_json::to_value(ApprovalMode::Bypass).unwrap();
        assert_eq!(json, "bypass");
    }

    #[test]
    fn author_phase_serialization() {
        let cases = [
            (AuthorPhase::Discovery, "discovery"),
            (AuthorPhase::PrewriteReview, "prewrite_review"),
            (AuthorPhase::Writing, "writing"),
            (AuthorPhase::PostwriteReview, "postwrite_review"),
            (AuthorPhase::Complete, "complete"),
            (AuthorPhase::Cancelled, "cancelled"),
        ];
        for (variant, expected) in cases {
            let json = serde_json::to_value(variant).unwrap();
            assert_eq!(json, expected);
        }
    }

    #[test]
    fn review_gate_serialization() {
        for (variant, expected) in [
            (ReviewGate::Prewrite, "prewrite"),
            (ReviewGate::Postwrite, "postwrite"),
            (ReviewGate::Copy, "copy"),
        ] {
            let json = serde_json::to_value(variant).unwrap();
            assert_eq!(json, expected);
        }
    }

    #[test]
    fn author_answer_serialization() {
        let cases = [
            (AuthorAnswer::ApproveProposal, "Approve proposal"),
            (AuthorAnswer::RequestChanges, "Request changes"),
            (AuthorAnswer::Cancel, "Cancel"),
            (AuthorAnswer::ApproveSuite, "Approve suite"),
            (AuthorAnswer::CopyCommand, "Copy command"),
            (AuthorAnswer::Skip, "Skip"),
        ];
        for (variant, expected) in cases {
            let json = serde_json::to_value(variant).unwrap();
            assert_eq!(json, expected);
        }
    }

    #[test]
    fn full_state_serialization_round_trip() {
        let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
        let json = serde_json::to_value(&state).unwrap();
        let loaded: AuthorWorkflowState = serde_json::from_value(json).unwrap();
        assert_eq!(loaded, state);
    }

    #[test]
    fn can_write_bypass_always_allows() {
        let state = make_state(AuthorPhase::Discovery, ApprovalMode::Bypass);
        assert!(can_write(&state).is_ok());
    }

    #[test]
    fn can_write_writing_phase_allows() {
        let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
        assert!(can_write(&state).is_ok());
    }

    #[test]
    fn can_write_discovery_denies() {
        let state = make_state(AuthorPhase::Discovery, ApprovalMode::Interactive);
        assert!(can_write(&state).is_err());
    }

    #[test]
    fn can_write_prewrite_review_denies() {
        let state = make_state(AuthorPhase::PrewriteReview, ApprovalMode::Interactive);
        assert!(can_write(&state).unwrap_err().contains("pre-write"));
    }

    #[test]
    fn can_write_postwrite_review_denies() {
        let state = make_state(AuthorPhase::PostwriteReview, ApprovalMode::Interactive);
        assert!(can_write(&state).unwrap_err().contains("post-write"));
    }

    #[test]
    fn can_write_complete_denies() {
        let state = make_state(AuthorPhase::Complete, ApprovalMode::Interactive);
        assert!(can_write(&state).unwrap_err().contains("approved"));
    }

    #[test]
    fn can_write_cancelled_denies() {
        let state = make_state(AuthorPhase::Cancelled, ApprovalMode::Interactive);
        assert!(can_write(&state).unwrap_err().contains("cancelled"));
    }

    #[test]
    fn can_request_gate_bypass_denies() {
        let state = make_state(AuthorPhase::Writing, ApprovalMode::Bypass);
        assert!(
            can_request_gate(&state, ReviewGate::Postwrite)
                .unwrap_err()
                .contains("bypass")
        );
    }

    #[test]
    fn can_request_prewrite_gate_in_prewrite_review() {
        let state = make_state(AuthorPhase::PrewriteReview, ApprovalMode::Interactive);
        assert!(can_request_gate(&state, ReviewGate::Prewrite).is_ok());
    }

    #[test]
    fn can_request_prewrite_gate_wrong_phase() {
        let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
        assert!(can_request_gate(&state, ReviewGate::Prewrite).is_err());
    }

    #[test]
    fn can_request_postwrite_gate_after_writing() {
        let mut state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
        state.draft.suite_tree_written = true;
        assert!(can_request_gate(&state, ReviewGate::Postwrite).is_ok());
    }

    #[test]
    fn can_request_postwrite_gate_without_writes_denies() {
        let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
        assert!(can_request_gate(&state, ReviewGate::Postwrite).is_err());
    }

    #[test]
    fn can_request_copy_gate_in_complete() {
        let state = make_state(AuthorPhase::Complete, ApprovalMode::Interactive);
        assert!(can_request_gate(&state, ReviewGate::Copy).is_ok());
    }

    #[test]
    fn can_request_copy_gate_wrong_phase() {
        let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
        assert!(can_request_gate(&state, ReviewGate::Copy).is_err());
    }

    #[test]
    fn can_stop_bypass_allows() {
        let state = make_state(AuthorPhase::Writing, ApprovalMode::Bypass);
        assert!(can_stop(&state).is_ok());
    }

    #[test]
    fn can_stop_cancelled_allows() {
        let state = make_state(AuthorPhase::Cancelled, ApprovalMode::Interactive);
        assert!(can_stop(&state).is_ok());
    }

    #[test]
    fn can_stop_writing_denies() {
        let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
        assert!(can_stop(&state).unwrap_err().contains("post-write"));
    }

    #[test]
    fn can_stop_postwrite_review_denies() {
        let state = make_state(AuthorPhase::PostwriteReview, ApprovalMode::Interactive);
        assert!(can_stop(&state).unwrap_err().contains("post-write"));
    }

    #[test]
    fn next_action_none() {
        assert_eq!(next_action(None), AuthorNextAction::ReloadState);
        assert!(next_action(None).to_string().contains("Reload"));
    }

    #[test]
    fn next_action_bypass() {
        let state = make_state(AuthorPhase::Discovery, ApprovalMode::Bypass);
        assert_eq!(next_action(Some(&state)), AuthorNextAction::ContinueBypass);
        assert!(next_action(Some(&state)).to_string().contains("bypass"));
    }

    #[test]
    fn next_action_each_phase() {
        let phases = [
            (AuthorPhase::Discovery, "discovery"),
            (AuthorPhase::PrewriteReview, "pre-write"),
            (AuthorPhase::PostwriteReview, "post-write"),
            (AuthorPhase::Cancelled, "cancelled"),
            (AuthorPhase::Complete, "approved"),
        ];
        for (phase, expected_substr) in phases {
            let state = make_state(phase, ApprovalMode::Interactive);
            let action = next_action(Some(&state));
            assert!(
                action.to_string().to_lowercase().contains(expected_substr),
                "phase {phase:?} action should contain '{expected_substr}': {action}"
            );
        }
    }

    #[test]
    fn next_action_writing_with_suite_written() {
        let mut state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
        state.draft.suite_tree_written = true;
        assert_eq!(next_action(Some(&state)), AuthorNextAction::ApplyEditRound);
        assert!(next_action(Some(&state)).to_string().contains("edit round"));
    }

    #[test]
    fn next_action_writing_without_suite_written() {
        let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
        assert_eq!(
            next_action(Some(&state)),
            AuthorNextAction::ContinueInitialWrite
        );
        assert!(next_action(Some(&state)).to_string().contains("initial"));
    }

    #[test]
    fn suite_author_path_allowed_suite_md() {
        let suite = Path::new("/tmp/suite");
        assert!(suite_author_path_allowed(&suite.join("suite.md"), suite));
    }

    #[test]
    fn suite_author_path_allowed_groups() {
        let suite = Path::new("/tmp/suite");
        assert!(suite_author_path_allowed(
            &suite.join("groups").join("g1.md"),
            suite
        ));
    }

    #[test]
    fn suite_author_path_allowed_baseline() {
        let suite = Path::new("/tmp/suite");
        assert!(suite_author_path_allowed(
            &suite.join("baseline").join("b1.yaml"),
            suite
        ));
    }

    #[test]
    fn suite_author_path_denied_outside() {
        let suite = Path::new("/tmp/suite");
        assert!(!suite_author_path_allowed(
            Path::new("/tmp/other/file.md"),
            suite
        ));
    }

    #[test]
    fn suite_author_path_denied_random_file_in_suite() {
        let suite = Path::new("/tmp/suite");
        assert!(!suite_author_path_allowed(&suite.join("random.txt"), suite));
    }

    #[test]
    fn has_written_suite_delegates_to_draft() {
        let mut state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
        assert!(!state.has_written_suite());
        state.draft.suite_tree_written = true;
        assert!(state.has_written_suite());
    }

    #[test]
    fn session_info_suite_path() {
        let info = AuthorSessionInfo {
            repo_root: None,
            feature: None,
            suite_name: None,
            suite_dir: Some("/tmp/suite".to_string()),
        };
        assert_eq!(info.suite_path(), Some(PathBuf::from("/tmp/suite")));

        let info_none = AuthorSessionInfo {
            repo_root: None,
            feature: None,
            suite_name: None,
            suite_dir: None,
        };
        assert_eq!(info_none.suite_path(), None);
    }

    #[test]
    fn migrate_author_v1_to_v2_nests_state_payload() {
        let v1 = json!({
            "schema_version": 1,
            "mode": "interactive",
            "phase": "writing",
            "session": {
                "suite_dir": "/tmp/suite"
            },
            "review": {
                "gate": "prewrite",
                "awaiting_answer": true,
                "round": 2,
                "last_answer": "Request changes"
            },
            "draft": {
                "suite_tree_written": true,
                "written_paths": ["suite.md"]
            },
            "updated_at": "2025-01-01T00:00:00Z",
            "transition_count": 3,
            "last_event": "RequestChanges"
        });

        let migrated = migrate_author_v1_to_v2(v1).unwrap();
        assert_eq!(migrated["schema_version"], 2);
        assert_eq!(migrated["state"]["phase"], "writing");
        assert_eq!(migrated["state"]["review"]["round"], 2);
        assert_eq!(migrated["state"]["draft"]["written_paths"][0], "suite.md");
    }

    #[test]
    fn author_repository_load_migrates_flat_v1_state() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("suite-new-state.json");
        let repo = author_repository_for_path(path.clone());
        let v1 = json!({
            "schema_version": 1,
            "mode": "interactive",
            "phase": "discovery",
            "session": {
                "suite_dir": "/tmp/suite"
            },
            "review": {
                "awaiting_answer": false,
                "round": 0
            },
            "draft": {
                "suite_tree_written": false,
                "written_paths": []
            },
            "updated_at": "2025-01-01T00:00:00Z",
            "transition_count": 0,
            "last_event": "ApprovalFlowStarted"
        });
        fs::write(&path, serde_json::to_string_pretty(&v1).unwrap()).unwrap();

        let state = repo.load().unwrap().unwrap();
        assert_eq!(state.schema_version, 2);
        assert_eq!(state.phase, AuthorPhase::Discovery);

        let on_disk: Value = serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap();
        assert_eq!(on_disk["schema_version"], 2);
        assert_eq!(on_disk["state"]["phase"], "discovery");
    }
}
