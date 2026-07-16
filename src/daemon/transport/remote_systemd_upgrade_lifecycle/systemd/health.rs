use std::thread;
use std::time::{Duration, Instant};

use crate::errors::CliError;

use super::super::super::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use super::super::files::{io_error, running_binary_sha256};
use super::super::model::{
    RemoteSystemdHealthReport, RemoteSystemdOperationPlan, SystemdObservation,
};
use super::{observe_systemd, process_environment};

pub(crate) fn verify_remote_systemd_health<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    expected_sha256: &str,
    run_systemctl: &RunSystemctl,
) -> Result<RemoteSystemdHealthReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let started = Instant::now();
    let deadline = started.checked_add(plan.readiness_timeout);
    let mut stable_process = None;
    let mut attempts = 0_u64;
    loop {
        attempts = attempts.saturating_add(1);
        let observation = observe_systemd(plan, run_systemctl)?;
        if readiness_deadline_expired(started.elapsed(), plan.readiness_timeout) {
            return Err(readiness_timeout_error(
                plan,
                expected_sha256,
                &observation,
                "",
            ));
        }
        let observed_sha = running_binary_sha256(observation.main_pid, deadline)
            .unwrap_or_default()
            .unwrap_or_default();
        if readiness_deadline_expired(started.elapsed(), plan.readiness_timeout) {
            return Err(readiness_timeout_error(
                plan,
                expected_sha256,
                &observation,
                &observed_sha,
            ));
        }
        if observation_is_ready(&observation, &observed_sha, expected_sha256) {
            refresh_stable_process(&mut stable_process, &observation);
        } else {
            stable_process = None;
        }
        let bound_process = process_environment::bind_ready_process(
            plan,
            expected_sha256,
            &observation,
            &observed_sha,
            deadline,
            run_systemctl,
        )?;
        if readiness_deadline_expired(started.elapsed(), plan.readiness_timeout) {
            return Err(readiness_timeout_error(
                plan,
                expected_sha256,
                &observation,
                &observed_sha,
            ));
        }
        if let Some((observation, observed_sha)) = bound_process {
            let stable = stable_process
                .as_ref()
                .ok_or_else(|| io_error("stable process observation disappeared"))?;
            if stable.since.elapsed() >= plan.stabilization_window {
                return Ok(RemoteSystemdHealthReport {
                    status: "ready".to_string(),
                    attempts,
                    main_pid: observation.main_pid,
                    n_restarts: observation.n_restarts,
                    active_state: observation.active_state,
                    sub_state: observation.sub_state,
                    observed_sha256: observed_sha,
                });
            }
        } else {
            stable_process = None;
        }
        let remaining = plan.readiness_timeout.saturating_sub(started.elapsed());
        thread::sleep(Duration::from_millis(250).min(remaining));
        if readiness_deadline_expired(started.elapsed(), plan.readiness_timeout) {
            return Err(readiness_timeout_error(
                plan,
                expected_sha256,
                &observation,
                &observed_sha,
            ));
        }
    }
}

fn readiness_deadline_expired(elapsed: Duration, readiness_timeout: Duration) -> bool {
    elapsed >= readiness_timeout
}

fn readiness_timeout_error(
    plan: &RemoteSystemdOperationPlan,
    expected_sha256: &str,
    observation: &SystemdObservation,
    observed_sha256: &str,
) -> CliError {
    io_error(format!(
        "{} did not become ready: ActiveState={}, SubState={}, MainPID={}, NRestarts={}, expected_sha256={}, observed_sha256={}",
        plan.service(),
        observation.active_state,
        observation.sub_state,
        observation.main_pid,
        observation.n_restarts,
        expected_sha256,
        observed_sha256
    ))
}

pub(super) fn observation_is_ready(
    observation: &SystemdObservation,
    observed_sha256: &str,
    expected_sha256: &str,
) -> bool {
    observation.active_state == "active"
        && observation.sub_state == "running"
        && observation.main_pid > 0
        && observed_sha256 == expected_sha256
}

struct StableProcess {
    since: Instant,
    main_pid: u32,
    n_restarts: u64,
}

fn refresh_stable_process(
    stable_process: &mut Option<StableProcess>,
    observation: &SystemdObservation,
) -> bool {
    let unchanged = stable_process.as_ref().is_some_and(|stable| {
        stable.main_pid == observation.main_pid && stable.n_restarts == observation.n_restarts
    });
    if unchanged {
        false
    } else {
        *stable_process = Some(StableProcess {
            since: Instant::now(),
            main_pid: observation.main_pid,
            n_restarts: observation.n_restarts,
        });
        true
    }
}

#[cfg(test)]
pub(crate) fn stability_reset_sequence_for_tests() -> (bool, bool, bool) {
    let mut stable = None;
    let first = SystemdObservation {
        active_state: "active".to_string(),
        sub_state: "running".to_string(),
        main_pid: 10,
        n_restarts: 0,
    };
    let changed_pid = SystemdObservation {
        main_pid: 11,
        ..first.clone()
    };
    (
        refresh_stable_process(&mut stable, &first),
        refresh_stable_process(&mut stable, &first),
        refresh_stable_process(&mut stable, &changed_pid),
    )
}

#[cfg(test)]
pub(crate) fn restart_stability_behavior_for_tests() -> (bool, bool, bool, bool) {
    let mut stable = None;
    let historical_restarts = SystemdObservation {
        active_state: "active".to_string(),
        sub_state: "running".to_string(),
        main_pid: 10,
        n_restarts: 3,
    };
    let another_restart = SystemdObservation {
        n_restarts: 4,
        ..historical_restarts.clone()
    };
    (
        observation_is_ready(&historical_restarts, "digest", "digest"),
        refresh_stable_process(&mut stable, &historical_restarts),
        refresh_stable_process(&mut stable, &historical_restarts),
        refresh_stable_process(&mut stable, &another_restart),
    )
}

#[cfg(test)]
mod tests {
    use super::readiness_deadline_expired;
    use std::time::Duration;

    #[test]
    fn readiness_deadline_is_checked_before_late_success() {
        let timeout = Duration::from_secs(12);
        assert!(!readiness_deadline_expired(
            Duration::from_secs(11),
            timeout
        ));
        assert!(readiness_deadline_expired(timeout, timeout));
        let after_timeout = Duration::from_secs(13);
        assert!(readiness_deadline_expired(after_timeout, timeout));
    }
}
