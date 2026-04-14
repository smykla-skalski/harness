use std::path::PathBuf;

use serde::Serialize;

use crate::errors::CliError;
use crate::infra::io::read_json_typed;
use crate::run::args::RunDirArgs;
use crate::run::context::{CurrentRunPointer, RunMetadata};
use crate::run::workflow::RunnerWorkflowState;
use crate::run::RunStatus;
use crate::workspace::current_run_context_path;

use super::helpers::explicit_run_dir;
use crate::kernel::topology::ClusterSpec;

#[derive(Debug, Clone, Serialize)]
pub struct RunDiagnosticTarget {
    pub run_dir: String,
    pub current_run_pointer: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct RunDiagnosticCheck {
    pub code: &'static str,
    pub kind: &'static str,
    pub status: &'static str,
    pub summary: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    pub repairable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hint: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct RunDiagnosticReport {
    pub ok: bool,
    pub command: &'static str,
    pub target: RunDiagnosticTarget,
    pub checks: Vec<RunDiagnosticCheck>,
    pub repairs_applied: Vec<RunDiagnosticCheck>,
    pub remaining_findings: Vec<RunDiagnosticCheck>,
}

#[derive(Debug, Clone)]
pub(super) enum PointerState {
    Missing,
    Invalid(String),
    Present(Box<CurrentRunPointer>),
}

#[derive(Debug, Clone)]
pub(super) struct ResolvedRunTarget {
    pub(super) explicit: bool,
    pub(super) requested_run_dir: Option<PathBuf>,
    pub(super) pointer_path: PathBuf,
    pub(super) pointer_state: PointerState,
}

pub(super) struct LoadedRunArtifacts {
    pub(super) metadata: Option<RunMetadata>,
    pub(super) status: Option<RunStatus>,
    pub(super) workflow: Option<RunnerWorkflowState>,
    pub(super) cluster: Option<ClusterSpec>,
}

impl ResolvedRunTarget {
    pub(super) fn resolve(args: &RunDirArgs) -> Result<Self, CliError> {
        let explicit_run_dir = explicit_run_dir(args)?;
        let pointer_path = current_run_context_path()?;
        let pointer_state = if pointer_path.exists() {
            match read_json_typed::<CurrentRunPointer>(&pointer_path) {
                Ok(pointer) => PointerState::Present(Box::new(pointer)),
                Err(error) => PointerState::Invalid(error.to_string()),
            }
        } else {
            PointerState::Missing
        };
        let requested_run_dir = explicit_run_dir.clone().or_else(|| match &pointer_state {
            PointerState::Present(pointer) => Some(pointer.layout.run_dir()),
            PointerState::Missing | PointerState::Invalid(_) => None,
        });

        Ok(Self {
            explicit: explicit_run_dir.is_some(),
            requested_run_dir,
            pointer_path,
            pointer_state,
        })
    }

    pub(super) fn target_label(&self) -> String {
        self.requested_run_dir.as_ref().map_or_else(
            || "current-session".to_string(),
            |path| path.display().to_string(),
        )
    }
}
