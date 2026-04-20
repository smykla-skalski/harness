//! External session discovery and adoption.

use std::io;
use std::path::{Path, PathBuf};

use fs_err as fs;
use serde_json::Value;
use thiserror::Error;
use tracing::info;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::read_json_typed;
use crate::session::storage;
use crate::session::storage::ActiveRegistry;
use crate::session::types::{CURRENT_VERSION, SessionState};
use crate::workspace::layout::SessionLayout;
use crate::workspace::utc_now;

#[derive(Debug, Error)]
pub enum AdoptionError {
    #[error("layout violation: {reason}")]
    LayoutViolation { reason: String },
    #[error("unsupported schema version: found {found}, supported {supported}")]
    UnsupportedSchemaVersion { found: u32, supported: u32 },
    #[error("origin mismatch: expected {expected}, found {found}")]
    OriginMismatch { expected: String, found: String },
    #[error("session {session_id} already attached")]
    AlreadyAttached { session_id: String },
    #[error("project-dir path has no file_name component")]
    InvalidProjectDir,
    #[error("I/O: {source}")]
    Io {
        #[from]
        source: io::Error,
    },
    #[error("parse: {0}")]
    Parse(String),
    #[error("storage: {0}")]
    Storage(String),
}

impl From<AdoptionError> for CliError {
    fn from(value: AdoptionError) -> Self {
        CliErrorKind::workflow_io(format!("session adopter: {value}")).into()
    }
}

#[derive(Debug, Clone)]
pub struct ProbedSession {
    state: SessionState,
    session_root: PathBuf,
}

impl ProbedSession {
    #[must_use]
    pub fn session_id(&self) -> &str {
        &self.state.session_id
    }

    #[must_use]
    pub fn project_name(&self) -> &str {
        &self.state.project_name
    }

    #[must_use]
    pub fn session_root(&self) -> &Path {
        &self.session_root
    }

    #[must_use]
    pub fn state(&self) -> &SessionState {
        &self.state
    }
}

#[derive(Debug, Clone)]
pub struct AdoptionOutcome {
    pub state: SessionState,
    pub layout: SessionLayout,
    pub external_origin: Option<PathBuf>,
}

pub struct SessionAdopter;

impl SessionAdopter {
    /// Validate an on-disk B-layout session directory. Reads `state.json` and `.origin`
    /// without mutating anything. Does not re-check sandbox bookmarks; the caller is
    /// expected to have the appropriate read permission.
    ///
    /// # Errors
    /// Returns [`AdoptionError::LayoutViolation`] when required paths are missing.
    /// Returns [`AdoptionError::UnsupportedSchemaVersion`] when the schema version
    /// does not match [`CURRENT_VERSION`]. Returns [`AdoptionError::OriginMismatch`]
    /// when the `.origin` marker does not match `state.json`'s `origin_path`.
    /// Returns [`AdoptionError::Io`] on filesystem failures.
    /// Returns [`AdoptionError::Parse`] on JSON decode failures.
    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    pub fn probe(session_root: &Path) -> Result<ProbedSession, AdoptionError> {
        let state_path = session_root.join("state.json");
        if !state_path.is_file() {
            return Err(AdoptionError::LayoutViolation {
                reason: "missing state.json".into(),
            });
        }
        let bytes = fs::read(&state_path)?;
        let raw: Value = serde_json::from_slice(&bytes)
            .map_err(|error| AdoptionError::Parse(format!("state.json: {error}")))?;
        let schema_version = raw
            .get("schema_version")
            .and_then(Value::as_u64)
            .and_then(|version| u32::try_from(version).ok())
            .unwrap_or_default();
        if schema_version != CURRENT_VERSION {
            return Err(AdoptionError::UnsupportedSchemaVersion {
                found: schema_version,
                supported: CURRENT_VERSION,
            });
        }
        let state: SessionState = serde_json::from_value(raw)
            .map_err(|error| AdoptionError::Parse(format!("state.json decode: {error}")))?;
        if !session_root.join("workspace").is_dir() {
            return Err(AdoptionError::LayoutViolation {
                reason: "missing workspace/".into(),
            });
        }
        if !session_root.join("memory").is_dir() {
            return Err(AdoptionError::LayoutViolation {
                reason: "missing memory/".into(),
            });
        }
        let marker_path = session_root.join(".origin");
        if !marker_path.is_file() {
            return Err(AdoptionError::LayoutViolation {
                reason: "missing .origin".into(),
            });
        }
        let marker = fs::read_to_string(&marker_path)?.trim().to_string();
        let expected = state.origin_path.to_string_lossy().to_string();
        if marker != expected {
            return Err(AdoptionError::OriginMismatch {
                expected,
                found: marker,
            });
        }
        info!(target: "harness::adopter", session_id = %state.session_id, "probe ok");
        Ok(ProbedSession {
            state,
            session_root: session_root.to_path_buf(),
        })
    }

    /// Register a probed session into the daemon's per-project `.active.json` and
    /// persist the session state with `external_origin` + `adopted_at` populated.
    ///
    /// `data_root_sessions` is the daemon's canonical sessions root
    /// (`<data_root>/sessions`). When the probed session root lives outside that
    /// prefix, the session is flagged `external_origin = Some(session_root)`.
    ///
    /// # Errors
    /// Returns [`AdoptionError::InvalidProjectDir`] when the session root path has
    /// insufficient parent components. Returns [`AdoptionError::AlreadyAttached`]
    /// when a state file already exists for this session id. Returns
    /// [`AdoptionError::Storage`] on persistence failures.
    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    pub fn register(
        probed: ProbedSession,
        data_root_sessions: &Path,
    ) -> Result<AdoptionOutcome, AdoptionError> {
        let ProbedSession {
            state,
            session_root,
        } = probed;

        let project_dir = session_root
            .parent()
            .ok_or(AdoptionError::InvalidProjectDir)?
            .to_path_buf();
        let sessions_root_for_layout = project_dir
            .parent()
            .ok_or(AdoptionError::InvalidProjectDir)?
            .to_path_buf();
        let project_name = project_dir
            .file_name()
            .map(|value| value.to_string_lossy().into_owned())
            .ok_or(AdoptionError::InvalidProjectDir)?;

        let layout = SessionLayout {
            sessions_root: sessions_root_for_layout.clone(),
            project_name,
            session_id: state.session_id.clone(),
        };

        let external_origin = if sessions_root_for_layout.starts_with(data_root_sessions) {
            None
        } else {
            Some(session_root)
        };

        // AlreadyAttached is defined by presence in the per-project .active.json
        // registry, not by whether a state.json file exists. External sessions have
        // a pre-existing state.json (the probe source), so we must not treat that
        // file as evidence of prior registration.
        // Read the registry directly from the layout path to avoid going through
        // the daemon's canonical harness_data_root().
        let registry: ActiveRegistry =
            read_json_typed(&layout.active_registry()).unwrap_or_default();
        if registry.sessions.contains_key(&state.session_id) {
            return Err(AdoptionError::AlreadyAttached {
                session_id: state.session_id,
            });
        }

        // Stamp adoption metadata onto the state, then persist in place.
        let state = storage::update_state(&layout, |s| {
            s.external_origin.clone_from(&external_origin);
            s.adopted_at = Some(utc_now());
            s.schema_version = CURRENT_VERSION;
            Ok(())
        })
        .map_err(|error| AdoptionError::Storage(error.to_string()))?;
        storage::register_active(&layout)
            .map_err(|error| AdoptionError::Storage(error.to_string()))?;
        info!(
            target: "harness::adopter",
            session_id = %state.session_id,
            external = %external_origin.is_some(),
            "register ok"
        );
        Ok(AdoptionOutcome {
            state,
            layout,
            external_origin,
        })
    }
}

#[cfg(test)]
mod tests;
