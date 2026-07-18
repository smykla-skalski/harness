use chrono::{DateTime, Duration, Utc};
use sha2::{Digest, Sha256};

use crate::task_board::{
    TaskBoardAutomationRetrySettings, TaskBoardFailureClass, TaskBoardRetrySchedule,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaskBoardAttemptRetryDecision {
    Retry(TaskBoardRetrySchedule),
    HumanRequired,
}

#[must_use]
pub fn task_board_attempt_retry_decision(
    settings: &TaskBoardAutomationRetrySettings,
    stable_key: &str,
    action_key: &str,
    failed_attempt: u32,
    failure_class: TaskBoardFailureClass,
    now: DateTime<Utc>,
) -> TaskBoardAttemptRetryDecision {
    let max_attempts = settings.max_attempts.max(1);
    if failure_class != TaskBoardFailureClass::Transient || failed_attempt >= max_attempts {
        return TaskBoardAttemptRetryDecision::HumanRequired;
    }
    let delay_seconds = retry_delay_seconds(settings, stable_key, failed_attempt);
    let delay = Duration::seconds(i64::try_from(delay_seconds).unwrap_or(i64::MAX));
    TaskBoardAttemptRetryDecision::Retry(TaskBoardRetrySchedule {
        action_key: action_key.to_string(),
        next_attempt: failed_attempt.saturating_add(1),
        failure_class,
        available_at: (now + delay).to_rfc3339(),
    })
}

fn retry_delay_seconds(
    settings: &TaskBoardAutomationRetrySettings,
    stable_key: &str,
    failed_attempt: u32,
) -> u64 {
    let exponent = failed_attempt.saturating_sub(1);
    let multiplier = u64::from(settings.multiplier.max(1));
    let exponential = (0..exponent).fold(settings.base_delay_seconds, |delay, _| {
        delay.saturating_mul(multiplier)
    });
    let maximum = settings.max_delay_seconds.max(1);
    let capped = exponential.min(maximum);
    deterministic_jitter(
        capped,
        stable_key,
        failed_attempt,
        settings.deterministic_jitter_percent,
    )
    .min(maximum)
}

fn deterministic_jitter(base: u64, stable_key: &str, attempt: u32, percent: u8) -> u64 {
    let percent = u64::from(percent.min(100));
    if percent == 0 || base == 0 {
        return base;
    }
    let digest = Sha256::digest(format!("{stable_key}:{attempt}").as_bytes());
    let sample = u64::from_be_bytes(
        digest[..8]
            .try_into()
            .expect("sha256 prefix is eight bytes"),
    );
    let span = percent.saturating_mul(2).saturating_add(1);
    let offset = i128::from(sample % span) - i128::from(percent);
    let scaled = i128::from(base).saturating_mul(100_i128.saturating_add(offset)) / 100;
    u64::try_from(scaled.max(1)).unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone;

    use super::*;

    #[test]
    fn transient_retry_is_deterministic_and_bounded() {
        let settings = TaskBoardAutomationRetrySettings {
            max_attempts: 4,
            base_delay_seconds: 10,
            multiplier: 3,
            max_delay_seconds: 50,
            deterministic_jitter_percent: 0,
        };
        let now = Utc.with_ymd_and_hms(2026, 7, 17, 10, 0, 0).unwrap();

        let first = task_board_attempt_retry_decision(
            &settings,
            "execution:reviewer",
            "review:reviewer",
            1,
            TaskBoardFailureClass::Transient,
            now,
        );
        let third = task_board_attempt_retry_decision(
            &settings,
            "execution:reviewer",
            "review:reviewer",
            3,
            TaskBoardFailureClass::Transient,
            now,
        );

        assert_eq!(retry_at(first), "2026-07-17T10:00:10+00:00");
        assert_eq!(retry_at(third), "2026-07-17T10:00:50+00:00");
    }

    #[test]
    fn exhausted_or_non_transient_attempt_requires_human() {
        let settings = TaskBoardAutomationRetrySettings::default();
        let now = Utc.with_ymd_and_hms(2026, 7, 17, 10, 0, 0).unwrap();

        for (attempt, class) in [
            (settings.max_attempts, TaskBoardFailureClass::Transient),
            (1, TaskBoardFailureClass::Configuration),
        ] {
            assert_eq!(
                task_board_attempt_retry_decision(
                    &settings,
                    "execution:reviewer",
                    "review:reviewer",
                    attempt,
                    class,
                    now,
                ),
                TaskBoardAttemptRetryDecision::HumanRequired
            );
        }
    }

    fn retry_at(decision: TaskBoardAttemptRetryDecision) -> String {
        match decision {
            TaskBoardAttemptRetryDecision::Retry(schedule) => schedule.available_at,
            TaskBoardAttemptRetryDecision::HumanRequired => panic!("expected retry"),
        }
    }
}
