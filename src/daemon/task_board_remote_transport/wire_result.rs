use serde::{Deserialize, Serialize};

use crate::task_board::{
    TaskBoardAttemptResultArtifactExpectation, TaskBoardExecutionPhase,
    TaskBoardLocalAttemptResult, TaskBoardLocalAttemptResultExpectation, TaskBoardWorkflowKind,
    validate_task_board_local_attempt_result,
};

use super::wire::{RemoteAttemptBinding, RemoteWireError, domain_digest, require_digest};

pub(crate) const MAX_REMOTE_TYPED_RESULT_BYTES: usize = 2 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RemoteTypedResult {
    pub(crate) offer_request_sha256: String,
    pub(crate) result: TaskBoardLocalAttemptResult,
    pub(crate) result_sha256: String,
}

impl RemoteTypedResult {
    pub(crate) fn seal(
        result: TaskBoardLocalAttemptResult,
        offer_request_sha256: String,
    ) -> Result<Self, RemoteWireError> {
        require_digest("offer_request_sha256", &offer_request_sha256)?;
        let result_sha256 = domain_digest(
            "harness.task-board.remote-result.v1",
            &(&offer_request_sha256, &result),
        )?;
        let sealed = Self {
            offer_request_sha256,
            result,
            result_sha256,
        };
        sealed.validate_serialized_size()?;
        Ok(sealed)
    }

    pub(crate) fn validate(
        &self,
        binding: &RemoteAttemptBinding,
        expected_offer_request_sha256: &str,
    ) -> Result<(), RemoteWireError> {
        self.validate_serialized_size()?;
        require_digest("offer_request_sha256", &self.offer_request_sha256)?;
        let expected = domain_digest(
            "harness.task-board.remote-result.v1",
            &(&self.offer_request_sha256, &self.result),
        )?;
        if self.result_sha256 != expected {
            return Err(RemoteWireError::DigestMismatch("result_sha256"));
        }
        if self.offer_request_sha256 != expected_offer_request_sha256
            || validate_task_board_local_attempt_result(
                &self.result,
                &result_expectation(binding)?,
            )
            .is_err()
        {
            return Err(RemoteWireError::ResultBindingMismatch);
        }
        Ok(())
    }

    pub(crate) fn validate_serialized_size(&self) -> Result<(), RemoteWireError> {
        let bytes = serde_json::to_vec(self).map_err(|_| RemoteWireError::Serialization)?;
        if bytes.len() <= MAX_REMOTE_TYPED_RESULT_BYTES {
            Ok(())
        } else {
            Err(RemoteWireError::ResultTooLarge)
        }
    }
}

fn result_expectation(
    binding: &RemoteAttemptBinding,
) -> Result<TaskBoardLocalAttemptResultExpectation<'_>, RemoteWireError> {
    let artifact = match binding.phase {
        TaskBoardExecutionPhase::Implementation => {
            TaskBoardAttemptResultArtifactExpectation::Implementation {
                revision_cycle: action_cycle(&binding.action_key, "implementation:")?,
                base_head_revision: &binding.base_revision,
            }
        }
        TaskBoardExecutionPhase::Review => TaskBoardAttemptResultArtifactExpectation::Review {
            profile_id: action_suffix(&binding.action_key, "review:")?,
            head_revision: binding
                .expected_head_revision
                .as_deref()
                .ok_or(RemoteWireError::ResultBindingMismatch)?,
        },
        TaskBoardExecutionPhase::Evaluate => {
            let exact_head_revision = binding
                .expected_head_revision
                .as_deref()
                .ok_or(RemoteWireError::ResultBindingMismatch)?;
            let write = matches!(
                binding.workflow_kind,
                TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix
            );
            let revision_cycle = if write {
                Some(action_cycle(&binding.action_key, "evaluate:")?)
            } else {
                if binding.action_key != "evaluate" {
                    return Err(RemoteWireError::ResultBindingMismatch);
                }
                None
            };
            TaskBoardAttemptResultArtifactExpectation::Evaluation {
                exact_head_revision,
                head_revision: write.then_some(exact_head_revision),
                revision_cycle,
            }
        }
        _ => return Err(RemoteWireError::ResultBindingMismatch),
    };
    Ok(TaskBoardLocalAttemptResultExpectation {
        execution_id: &binding.execution_id,
        action_key: &binding.action_key,
        attempt: binding.attempt,
        idempotency_key: &binding.idempotency_key,
        artifact,
    })
}

fn action_cycle(action_key: &str, prefix: &str) -> Result<u32, RemoteWireError> {
    action_suffix(action_key, prefix)?
        .parse()
        .ok()
        .filter(|cycle| *cycle > 0)
        .ok_or(RemoteWireError::ResultBindingMismatch)
}

fn action_suffix<'a>(
    action_key: &'a str,
    prefix: &str,
) -> Result<&'a str, RemoteWireError> {
    action_key
        .strip_prefix(prefix)
        .filter(|suffix| !suffix.is_empty())
        .ok_or(RemoteWireError::ResultBindingMismatch)
}
