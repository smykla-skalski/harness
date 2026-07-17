use crate::daemon::db::db_error;
use crate::daemon::protocol::TaskBoardUpdateItemRequest;
use crate::errors::CliError;
use crate::task_board::types::MAX_TASK_BOARD_ESTIMATE;

pub(super) fn validate_update_estimates(
    request: &TaskBoardUpdateItemRequest,
) -> Result<(), CliError> {
    validate_estimate_patch(
        "estimated_tokens",
        request.estimated_tokens,
        request.clear_estimates.clear_estimated_tokens,
    )?;
    validate_estimate_patch(
        "estimated_cost_microusd",
        request.estimated_cost_microusd,
        request.clear_estimates.clear_estimated_cost_microusd,
    )
}

fn validate_estimate_patch(name: &str, value: Option<u64>, clear: bool) -> Result<(), CliError> {
    if value.is_some() && clear {
        return Err(db_error(format!(
            "task-board {name} cannot be set and cleared together"
        )));
    }
    validate_estimate(name, value)
}

pub(super) fn validate_estimate(name: &str, value: Option<u64>) -> Result<(), CliError> {
    if value.is_none_or(|value| (1..=MAX_TASK_BOARD_ESTIMATE).contains(&value)) {
        return Ok(());
    }
    Err(db_error(format!(
        "task-board {name} must be between 1 and {MAX_TASK_BOARD_ESTIMATE}"
    )))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::daemon::protocol::{TaskBoardUpdateEstimateClears, TaskBoardUpdateItemRequest};

    #[test]
    fn estimates_accept_absence_and_the_persisted_range() {
        assert!(validate_estimate("estimate", None).is_ok());
        assert!(validate_estimate("estimate", Some(1)).is_ok());
        assert!(validate_estimate("estimate", Some(MAX_TASK_BOARD_ESTIMATE)).is_ok());
    }

    #[test]
    fn estimates_reject_zero_overflow_and_set_clear_conflicts() {
        assert!(validate_estimate("estimate", Some(0)).is_err());
        assert!(validate_estimate("estimate", Some(MAX_TASK_BOARD_ESTIMATE + 1)).is_err());
        let request = TaskBoardUpdateItemRequest {
            estimated_tokens: Some(1),
            clear_estimates: TaskBoardUpdateEstimateClears {
                clear_estimated_tokens: true,
                ..TaskBoardUpdateEstimateClears::default()
            },
            ..TaskBoardUpdateItemRequest::default()
        };

        assert!(validate_update_estimates(&request).is_err());
    }
}
