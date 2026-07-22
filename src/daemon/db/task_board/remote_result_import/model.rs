use std::path::Path;

use serde::Serialize;

use super::super::remote_assignment_model::{canonical_time, nonblank};
use crate::daemon::db::{CliError, db_error};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TaskBoardRemoteResultImportState {
    Prepared,
    Applied,
    Adopted,
    ManualRequired,
}

impl TaskBoardRemoteResultImportState {
    pub(super) const fn as_str(self) -> &'static str {
        match self {
            Self::Prepared => "prepared",
            Self::Applied => "applied",
            Self::Adopted => "adopted",
            Self::ManualRequired => "manual_required",
        }
    }

    fn decode(value: &str) -> Result<Self, CliError> {
        match value {
            "prepared" => Ok(Self::Prepared),
            "applied" => Ok(Self::Applied),
            "adopted" => Ok(Self::Adopted),
            "manual_required" => Ok(Self::ManualRequired),
            _ => Err(db_error("remote result import state is invalid")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct TaskBoardRemoteResultImportRequest {
    pub(crate) assignment_id: String,
    pub(crate) fencing_epoch: u64,
    pub(crate) worktree_path: String,
    pub(crate) git_dir: String,
    pub(crate) common_git_dir: String,
    pub(crate) branch_ref: String,
    pub(crate) base_revision: String,
    pub(crate) result_revision: String,
    pub(crate) advertised_ref: String,
    pub(crate) import_ref: String,
    pub(crate) object_format: String,
    pub(crate) prepared_at: String,
}

impl TaskBoardRemoteResultImportRequest {
    pub(super) fn validate(&self) -> Result<(), CliError> {
        nonblank(&self.assignment_id, "remote result import assignment")?;
        if self.fencing_epoch == 0
            || !canonical_path(&self.worktree_path)
            || !canonical_path(&self.git_dir)
            || !canonical_path(&self.common_git_dir)
            || !canonical_ref(&self.branch_ref, "refs/heads/")
            || !canonical_ref(&self.advertised_ref, "refs/harness/task-board/results/")
            || !canonical_ref(&self.import_ref, "refs/harness/task-board/imports/")
            || self.advertised_ref == self.import_ref
        {
            return Err(db_error(
                "remote result import coordinates are noncanonical",
            ));
        }
        let oid_len = match self.object_format.as_str() {
            "sha1" => 40,
            "sha256" => 64,
            _ => {
                return Err(db_error(
                    "remote result import object format is unsupported",
                ));
            }
        };
        if !canonical_oid(&self.base_revision, oid_len)
            || !canonical_oid(&self.result_revision, oid_len)
            || self.base_revision == self.result_revision
        {
            return Err(db_error("remote result import revisions are noncanonical"));
        }
        canonical_time(&self.prepared_at, "remote result import preparation time")?;
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteImplementationImportEvidence {
    pub(crate) import_sha256: String,
    pub(crate) bundle_sha256: String,
    pub(crate) base_head_revision: String,
    pub(crate) result_head_revision: String,
    pub(crate) advertised_ref: String,
    pub(crate) import_ref: String,
    pub(crate) verified_descends_from_base: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteResultImportRecord {
    pub(crate) assignment_id: String,
    pub(crate) fencing_epoch: u64,
    pub(crate) execution_id: String,
    pub(crate) action_key: String,
    pub(crate) attempt: u32,
    pub(crate) idempotency_key: String,
    pub(crate) offer_request_sha256: String,
    pub(crate) status_sha256: String,
    pub(crate) result_sha256: String,
    pub(crate) result_artifact_sha256: String,
    pub(crate) bundle_sha256: String,
    pub(crate) parent_record_sha256: String,
    pub(crate) worktree_path: String,
    pub(crate) git_dir: String,
    pub(crate) common_git_dir: String,
    pub(crate) branch_ref: String,
    pub(crate) base_revision: String,
    pub(crate) result_revision: String,
    pub(crate) advertised_ref: String,
    pub(crate) import_ref: String,
    pub(crate) object_format: String,
    pub(crate) import_sha256: String,
    pub(crate) state: TaskBoardRemoteResultImportState,
    pub(crate) prepared_at: String,
    pub(crate) applied_at: Option<String>,
    pub(crate) adopted_at: Option<String>,
    pub(crate) last_error: Option<String>,
}

impl TaskBoardRemoteResultImportRecord {
    pub(crate) fn evidence(&self) -> TaskBoardRemoteImplementationImportEvidence {
        TaskBoardRemoteImplementationImportEvidence {
            import_sha256: self.import_sha256.clone(),
            bundle_sha256: self.bundle_sha256.clone(),
            base_head_revision: self.base_revision.clone(),
            result_head_revision: self.result_revision.clone(),
            advertised_ref: self.advertised_ref.clone(),
            import_ref: self.import_ref.clone(),
            verified_descends_from_base: matches!(
                self.state,
                TaskBoardRemoteResultImportState::Applied
                    | TaskBoardRemoteResultImportState::Adopted
            ),
        }
    }

    pub(crate) fn request(&self) -> TaskBoardRemoteResultImportRequest {
        TaskBoardRemoteResultImportRequest {
            assignment_id: self.assignment_id.clone(),
            fencing_epoch: self.fencing_epoch,
            worktree_path: self.worktree_path.clone(),
            git_dir: self.git_dir.clone(),
            common_git_dir: self.common_git_dir.clone(),
            branch_ref: self.branch_ref.clone(),
            base_revision: self.base_revision.clone(),
            result_revision: self.result_revision.clone(),
            advertised_ref: self.advertised_ref.clone(),
            import_ref: self.import_ref.clone(),
            object_format: self.object_format.clone(),
            prepared_at: self.prepared_at.clone(),
        }
    }

    fn validate(&self) -> Result<(), CliError> {
        self.request().validate()?;
        nonblank(&self.execution_id, "remote result import execution")?;
        nonblank(&self.action_key, "remote result import action")?;
        nonblank(
            &self.idempotency_key,
            "remote result import idempotency key",
        )?;
        for (value, field) in [
            (&self.offer_request_sha256, "offer request"),
            (&self.status_sha256, "terminal status"),
            (&self.result_sha256, "typed result"),
            (&self.result_artifact_sha256, "result artifact"),
            (&self.bundle_sha256, "bundle"),
            (&self.parent_record_sha256, "parent record"),
            (&self.import_sha256, "import"),
        ] {
            if !canonical_sha256(value) {
                return Err(db_error(format!(
                    "remote result import {field} digest is noncanonical"
                )));
            }
        }
        self.validate_state()
    }

    fn validate_state(&self) -> Result<(), CliError> {
        let prepared = canonical_time(&self.prepared_at, "remote result import prepared time")?;
        let applied = self
            .applied_at
            .as_deref()
            .map(|value| canonical_time(value, "remote result import applied time"))
            .transpose()?;
        let adopted = self
            .adopted_at
            .as_deref()
            .map(|value| canonical_time(value, "remote result import adopted time"))
            .transpose()?;
        let ordered = applied.as_ref().is_none_or(|value| value >= &prepared)
            && adopted
                .as_ref()
                .is_none_or(|value| applied.as_ref().is_some_and(|applied| value >= applied));
        let error = self
            .last_error
            .as_deref()
            .is_some_and(|value| value.trim() == value && !value.is_empty() && value.len() <= 4096);
        let shape = match self.state {
            TaskBoardRemoteResultImportState::Prepared => {
                applied.is_none() && adopted.is_none() && self.last_error.is_none()
            }
            TaskBoardRemoteResultImportState::Applied => {
                applied.is_some() && adopted.is_none() && self.last_error.is_none()
            }
            TaskBoardRemoteResultImportState::Adopted => {
                applied.is_some() && adopted.is_some() && self.last_error.is_none()
            }
            TaskBoardRemoteResultImportState::ManualRequired => adopted.is_none() && error,
        };
        if ordered && shape {
            Ok(())
        } else {
            Err(db_error("remote result import durable state is invalid"))
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteResultImportWork {
    pub(crate) record: TaskBoardRemoteResultImportRecord,
    pub(crate) bundle: Vec<u8>,
}

#[derive(sqlx::FromRow)]
pub(super) struct RemoteResultImportRow {
    assignment_id: String,
    fencing_epoch: i64,
    execution_id: String,
    action_key: String,
    attempt: i64,
    idempotency_key: String,
    offer_request_sha256: String,
    status_sha256: String,
    result_sha256: String,
    result_artifact_sha256: String,
    bundle_sha256: String,
    parent_record_sha256: String,
    worktree_path: String,
    git_dir: String,
    common_git_dir: String,
    branch_ref: String,
    base_revision: String,
    result_revision: String,
    advertised_ref: String,
    import_ref: String,
    object_format: String,
    import_sha256: String,
    state: String,
    prepared_at: String,
    applied_at: Option<String>,
    adopted_at: Option<String>,
    last_error: Option<String>,
}

impl RemoteResultImportRow {
    pub(super) const SELECT: &'static str =
        "SELECT assignment_id, fencing_epoch, execution_id, action_key, attempt,
                idempotency_key, offer_request_sha256, status_sha256, result_sha256,
                result_artifact_sha256, bundle_sha256, parent_record_sha256,
                worktree_path, git_dir, common_git_dir, branch_ref, base_revision, result_revision,
                advertised_ref, import_ref, object_format, import_sha256, state,
                prepared_at, applied_at, adopted_at, last_error
         FROM task_board_remote_result_imports
         WHERE assignment_id = ?1 AND fencing_epoch = ?2";

    pub(super) fn into_record(self) -> Result<TaskBoardRemoteResultImportRecord, CliError> {
        let fencing_epoch = u64::try_from(self.fencing_epoch)
            .ok()
            .filter(|epoch| *epoch > 0)
            .ok_or_else(|| db_error("remote result import fencing epoch is invalid"))?;
        let attempt = u32::try_from(self.attempt)
            .ok()
            .filter(|attempt| *attempt > 0)
            .ok_or_else(|| db_error("remote result import attempt is invalid"))?;
        let record = TaskBoardRemoteResultImportRecord {
            assignment_id: self.assignment_id,
            fencing_epoch,
            execution_id: self.execution_id,
            action_key: self.action_key,
            attempt,
            idempotency_key: self.idempotency_key,
            offer_request_sha256: self.offer_request_sha256,
            status_sha256: self.status_sha256,
            result_sha256: self.result_sha256,
            result_artifact_sha256: self.result_artifact_sha256,
            bundle_sha256: self.bundle_sha256,
            parent_record_sha256: self.parent_record_sha256,
            worktree_path: self.worktree_path,
            git_dir: self.git_dir,
            common_git_dir: self.common_git_dir,
            branch_ref: self.branch_ref,
            base_revision: self.base_revision,
            result_revision: self.result_revision,
            advertised_ref: self.advertised_ref,
            import_ref: self.import_ref,
            object_format: self.object_format,
            import_sha256: self.import_sha256,
            state: TaskBoardRemoteResultImportState::decode(&self.state)?,
            prepared_at: self.prepared_at,
            applied_at: self.applied_at,
            adopted_at: self.adopted_at,
            last_error: self.last_error,
        };
        record.validate()?;
        Ok(record)
    }
}

fn canonical_path(value: &str) -> bool {
    let Some(relative) = value.strip_prefix('/') else {
        return false;
    };
    value.trim() == value
        && value.len() <= 4096
        && Path::new(value).is_absolute()
        && relative
            .split('/')
            .all(|part| !part.is_empty() && !matches!(part, "." | ".."))
}

fn canonical_ref(value: &str, prefix: &str) -> bool {
    let Some(name) = value.strip_prefix(prefix) else {
        return false;
    };
    !name.is_empty()
        && value.len() <= 1024
        && value.trim() == value
        && name != "@"
        && !name.starts_with(['-', '/', '.'])
        && !name.ends_with(['/', '.'])
        && name.bytes().all(|byte| (0x21..=0x7e).contains(&byte))
        && !name.contains([':', '\\', '~', '^', '?', '*', '['])
        && !name.contains("..")
        && !value.contains("//")
        && !name.contains("@{")
        && name.split('/').all(|component| {
            !component.is_empty() && !component.starts_with('.') && !component.ends_with(".lock")
        })
}

fn canonical_oid(value: &str, expected_len: usize) -> bool {
    value.len() == expected_len
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn canonical_sha256(value: &str) -> bool {
    canonical_oid(value, 64)
}
