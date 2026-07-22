use std::time::{Duration, Instant};

use chrono::{Duration as ChronoDuration, SecondsFormat, Utc};

use super::super::*;
use crate::daemon::db::TaskBoardRemoteRecoveryBatch;

#[test]
fn recovery_schedule_uses_earlier_remote_deadline() {
    let fallback = Duration::from_secs(30);
    let deadline =
        (Utc::now() + ChronoDuration::seconds(5)).to_rfc3339_opts(SecondsFormat::Secs, true);
    let scheduled = next_deadline(Some(&deadline), fallback).expect("remote deadline");
    assert!(scheduled <= Instant::now() + Duration::from_secs(6));

    let expired =
        (Utc::now() - ChronoDuration::seconds(5)).to_rfc3339_opts(SecondsFormat::Secs, true);
    let expired_wake = next_deadline(Some(&expired), fallback).expect("expired remote deadline");
    assert!(expired_wake >= Instant::now() + Duration::from_millis(900));
    assert!(expired_wake <= Instant::now() + Duration::from_secs(2));

    let mut incomplete = RecoverySchedule::new(fallback);
    incomplete.record_batch(
        &TaskBoardRemoteRecoveryBatch {
            incomplete: true,
            ..TaskBoardRemoteRecoveryBatch::default()
        },
        None,
    );
    assert!(incomplete.next_wake >= Instant::now() + Duration::from_millis(900));
    assert!(incomplete.next_wake <= Instant::now() + Duration::from_secs(2));
}

#[test]
fn failed_batches_grow_backoff_without_wall_clock_waiting() {
    let mut schedule = RecoverySchedule::new(Duration::from_secs(30));
    let failed = TaskBoardRemoteRecoveryBatch {
        failures: vec![crate::daemon::db::TaskBoardRemoteRecoveryFailure {
            assignment_id: "dead-executor-generation".into(),
            code: "CODEX001".into(),
            message: "executor unavailable".into(),
        }],
        ..TaskBoardRemoteRecoveryBatch::default()
    };
    let now = Instant::now();

    for (attempt, expected_delay) in [(1, 1), (2, 2), (3, 4), (4, 8)] {
        let attempt_now = now + Duration::from_secs(u64::from(attempt) * 100);
        schedule.record_batch_at(&failed, None, attempt_now);
        assert_eq!(schedule.consecutive_failures, attempt);
        assert_eq!(
            schedule.next_wake.duration_since(attempt_now),
            Duration::from_secs(expected_delay)
        );
    }
}

#[test]
fn verified_progress_resets_failure_backoff_deterministically() {
    let mut schedule = RecoverySchedule::new(Duration::from_secs(30));
    let now = Instant::now();

    schedule.record_failure_at(now);
    schedule.record_failure_at(now + Duration::from_secs(10));
    assert_eq!(schedule.consecutive_failures, 2);
    schedule.record_progress();
    assert_eq!(schedule.consecutive_failures, 0);
    let retry_now = now + Duration::from_secs(20);
    schedule.record_failure_at(retry_now);
    assert_eq!(schedule.next_wake.duration_since(retry_now), MINIMUM_RETRY);
}

#[test]
fn healthy_deadline_wins_over_a_blocked_generation_retry() {
    let mut schedule = RecoverySchedule::new(Duration::from_secs(30));
    let now = Instant::now();
    schedule.consecutive_failures = 3;
    schedule.next_wake = now + Duration::from_secs(5);

    schedule.record_failure_preserving_earlier_wake_at(now);

    assert_eq!(schedule.consecutive_failures, 4);
    assert_eq!(
        schedule.next_wake.duration_since(now),
        Duration::from_secs(5)
    );
    schedule.next_wake = now + Duration::from_secs(5);
    schedule.record_failure_preserving_earlier_wake_at(now);
    assert_eq!(
        schedule.next_wake.duration_since(now),
        Duration::from_secs(5)
    );
}

#[test]
fn controller_error_without_a_cursor_advance_keeps_exponential_backoff() {
    let mut schedule = RecoverySchedule::new(Duration::from_secs(30));
    let now = Instant::now();

    for (attempt, expected_delay) in [(1, 1), (2, 2), (3, 4)] {
        let attempt_now = now + Duration::from_secs(u64::from(attempt) * 100);
        schedule.record_controller_coverage_at(true, false, false, attempt_now);
        assert_eq!(schedule.consecutive_failures, attempt);
        assert_eq!(
            schedule.next_wake.duration_since(attempt_now),
            Duration::from_secs(expected_delay),
        );
    }
}

#[test]
fn controller_pagination_remains_prompt_without_resetting_retry_authority() {
    let mut schedule = RecoverySchedule::new(Duration::from_secs(30));
    let now = Instant::now();

    schedule.record_controller_coverage_at(true, false, false, now);
    schedule.record_controller_coverage_at(true, false, true, now + Duration::from_secs(10));

    assert_eq!(schedule.consecutive_failures, 2);
    assert_eq!(
        schedule
            .next_wake
            .duration_since(now + Duration::from_secs(10)),
        MINIMUM_RETRY,
    );
}

#[test]
fn recovery_backoff_caps_at_one_minute() {
    let mut schedule = RecoverySchedule::new(Duration::from_secs(30));
    let now = Instant::now();

    for attempt in 1_u32..=12 {
        let attempt_now = now + Duration::from_secs(u64::from(attempt) * 100);
        schedule.record_failure_at(attempt_now);
        assert_eq!(
            schedule.next_wake.duration_since(attempt_now),
            Duration::from_secs(if attempt < 7 {
                1_u64 << (attempt - 1)
            } else {
                60
            }),
        );
    }
}
