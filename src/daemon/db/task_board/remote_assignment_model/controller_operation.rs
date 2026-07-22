use crate::daemon::db::task_board::remote_lifecycle_trust::{
    TaskBoardRemoteLifecycleTrustSnapshot, decode_lifecycle_trust,
};
use crate::daemon::db::{CliError, db_error};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteControllerOperationToken {
    pub(crate) kind: String,
    pub(crate) request_sha256: String,
    pub(crate) trust_sha256: String,
    pub(crate) fence: Option<TaskBoardRemoteLifecycleTrustSnapshot>,
}

pub(super) fn decode(
    kind: Option<String>,
    request_sha256: Option<String>,
    trust_sha256: Option<String>,
    fence_json: Option<String>,
    fence_sha256: Option<String>,
) -> Result<Option<TaskBoardRemoteControllerOperationToken>, CliError> {
    match (kind, request_sha256, trust_sha256) {
        (None, None, None) if fence_json.is_none() && fence_sha256.is_none() => Ok(None),
        (Some(kind), Some(request_sha256), Some(trust_sha256)) => {
            validate_kind(&kind)?;
            validate_sha256(&request_sha256, "controller operation request")?;
            validate_sha256(&trust_sha256, "controller operation trust")?;
            let fence = decode_lifecycle_trust(fence_json, fence_sha256)?
                .ok_or_else(|| db_error("controller operation has no immutable lifecycle fence"))?;
            Ok(Some(TaskBoardRemoteControllerOperationToken {
                kind,
                request_sha256,
                trust_sha256,
                fence: Some(fence),
            }))
        }
        _ => Err(db_error(
            "controller operation trust evidence is incomplete",
        )),
    }
}

fn validate_kind(kind: &str) -> Result<(), CliError> {
    if matches!(
        kind,
        "upload_source_bundle"
            | "offer"
            | "claim"
            | "renew"
            | "status"
            | "cancel"
            | "settle"
            | "fetch_artifact"
            | "observe_cleanup"
    ) {
        Ok(())
    } else {
        Err(db_error("controller operation kind is invalid"))
    }
}

pub(super) fn requires_exact_generation(kind: &str) -> bool {
    matches!(kind, "upload_source_bundle" | "offer" | "claim" | "renew")
}

fn validate_sha256(value: &str, field: &str) -> Result<(), CliError> {
    if value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        Ok(())
    } else {
        Err(db_error(format!(
            "{field} digest must be canonical lowercase SHA-256"
        )))
    }
}
