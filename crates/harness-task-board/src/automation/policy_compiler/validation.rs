use super::{ResolvedScope, TaskBoardPolicyCompilationError, TaskBoardPolicyLimit};

const MAX_PERSISTED_ADMISSION_VALUE: u64 = i64::MAX as u64;

pub(super) fn validate_limit(
    limit: &TaskBoardPolicyLimit,
    scope: &ResolvedScope,
) -> Result<(), TaskBoardPolicyCompilationError> {
    let valid = match limit {
        TaskBoardPolicyLimit::Concurrency {
            limit, reservation, ..
        } => persisted_positive(*limit) && persisted_positive(*reservation),
        TaskBoardPolicyLimit::Rate {
            limit,
            window_seconds,
            reservation,
            ..
        } => {
            persisted_positive(*limit)
                && persisted_positive(*window_seconds)
                && persisted_positive(*reservation)
        }
        TaskBoardPolicyLimit::TokenBudget {
            limit,
            window_seconds,
            ..
        } => persisted_positive(*limit) && persisted_positive(*window_seconds),
        TaskBoardPolicyLimit::MonetaryBudget {
            limit_microusd,
            window_seconds,
            ..
        } => persisted_positive(*limit_microusd) && persisted_positive(*window_seconds),
    };
    valid
        .then_some(())
        .ok_or_else(|| TaskBoardPolicyCompilationError::InvalidLimit { scope: scope.key() })
}

const fn persisted_positive(value: u64) -> bool {
    value > 0 && value <= MAX_PERSISTED_ADMISSION_VALUE
}
