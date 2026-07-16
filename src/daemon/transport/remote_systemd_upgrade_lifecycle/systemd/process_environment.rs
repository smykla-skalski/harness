use std::io::{Error, ErrorKind};
use std::path::Path;
use std::time::Instant;

use fs_err as fs;

use crate::daemon::transport::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use crate::errors::CliError;

use super::super::files::{io_error, running_binary_sha256};
use super::super::model::{RemoteSystemdOperationPlan, SystemdObservation};
use super::health::observation_is_ready;
use super::observe_systemd;

pub(super) fn bind_ready_process<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    expected_sha256: &str,
    observation: &SystemdObservation,
    observed_sha256: &str,
    deadline: Option<Instant>,
    run_systemctl: &RunSystemctl,
) -> Result<Option<(SystemdObservation, String)>, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    if !observation_is_ready(observation, observed_sha256, expected_sha256) {
        return Ok(None);
    }
    if !validate_running_process_environment(plan, observation.main_pid)? {
        return Ok(None);
    }
    let rebound = observe_systemd(plan, run_systemctl)?;
    if !same_process_generation(observation, &rebound) {
        return Ok(None);
    }
    let Ok(Some(rebound_sha256)) = running_binary_sha256(rebound.main_pid, deadline) else {
        return Ok(None);
    };
    if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
        return Ok(None);
    }
    let confirmed = observe_systemd(plan, run_systemctl)?;
    if process_remained_ready_after_hash(&rebound, &confirmed, &rebound_sha256, expected_sha256) {
        Ok(Some((confirmed, rebound_sha256)))
    } else {
        Ok(None)
    }
}

fn process_remained_ready_after_hash(
    before_hash: &SystemdObservation,
    after_hash: &SystemdObservation,
    observed_sha256: &str,
    expected_sha256: &str,
) -> bool {
    same_process_generation(before_hash, after_hash)
        && observation_is_ready(after_hash, observed_sha256, expected_sha256)
}

pub(super) fn same_process_generation(
    before: &SystemdObservation,
    after: &SystemdObservation,
) -> bool {
    before.main_pid == after.main_pid && before.n_restarts == after.n_restarts
}

fn validate_running_process_environment(
    plan: &RemoteSystemdOperationPlan,
    pid: u32,
) -> Result<bool, CliError> {
    let path = Path::new("/proc").join(pid.to_string()).join("environ");
    let contents = match fs::read(&path) {
        Ok(contents) => contents,
        Err(error) if process_disappeared(&error) => return Ok(false),
        Err(error) => {
            return Err(io_error(format!(
                "read managed daemon process environment {}: {error}",
                path.display()
            )));
        }
    };
    validate_process_environment(plan, &contents)?;
    Ok(true)
}

fn process_disappeared(error: &Error) -> bool {
    error.kind() == ErrorKind::NotFound || error.raw_os_error() == Some(libc::ESRCH)
}

pub(super) fn validate_process_environment(
    plan: &RemoteSystemdOperationPlan,
    contents: &[u8],
) -> Result<(), CliError> {
    let data_home = format!("/var/lib/{}", plan.unit);
    for (name, expected_value) in [
        ("HARNESS_DAEMON_DATA_HOME", data_home.as_str()),
        ("XDG_DATA_HOME", data_home.as_str()),
        ("STATE_DIRECTORY", data_home.as_str()),
        ("HARNESS_DAEMON_OWNERSHIP", "external"),
    ] {
        require_process_assignment(contents, name, expected_value)?;
    }
    Ok(())
}

fn require_process_assignment(
    contents: &[u8],
    name: &str,
    expected_value: &str,
) -> Result<(), CliError> {
    let observed = contents
        .split(|byte| *byte == 0)
        .filter_map(split_assignment)
        .filter_map(|(key, value)| (key == name.as_bytes()).then_some(value))
        .collect::<Vec<_>>();
    if observed == [expected_value.as_bytes()] {
        Ok(())
    } else {
        let observed = observed
            .iter()
            .map(|value| String::from_utf8_lossy(value))
            .collect::<Vec<_>>();
        Err(io_error(format!(
            "managed daemon process environment requires exactly {name}={expected_value}, found {observed:?}"
        )))
    }
}

fn split_assignment(value: &[u8]) -> Option<(&[u8], &[u8])> {
    let separator = value.iter().position(|byte| *byte == b'=')?;
    Some((&value[..separator], &value[separator + 1..]))
}

#[cfg(test)]
pub(super) fn process_disappearance_errors_for_tests() -> (bool, bool, bool) {
    (
        process_disappeared(&Error::from(ErrorKind::NotFound)),
        process_disappeared(&Error::from_raw_os_error(libc::ESRCH)),
        process_disappeared(&Error::from(ErrorKind::PermissionDenied)),
    )
}

#[cfg(test)]
mod tests {
    use super::process_remained_ready_after_hash;
    use crate::daemon::transport::remote_systemd_upgrade_lifecycle::model::SystemdObservation;

    fn ready_observation() -> SystemdObservation {
        SystemdObservation {
            active_state: "active".to_string(),
            sub_state: "running".to_string(),
            main_pid: 42,
            n_restarts: 3,
        }
    }

    #[test]
    fn post_hash_observation_must_confirm_the_same_ready_generation() {
        let before_hash = ready_observation();
        assert!(process_remained_ready_after_hash(
            &before_hash,
            &before_hash,
            "digest",
            "digest"
        ));

        let changed_pid = SystemdObservation {
            main_pid: 43,
            ..before_hash.clone()
        };
        assert!(!process_remained_ready_after_hash(
            &before_hash,
            &changed_pid,
            "digest",
            "digest"
        ));

        let changed_restart = SystemdObservation {
            n_restarts: 4,
            ..before_hash.clone()
        };
        assert!(!process_remained_ready_after_hash(
            &before_hash,
            &changed_restart,
            "digest",
            "digest"
        ));

        let stopped = SystemdObservation {
            active_state: "inactive".to_string(),
            sub_state: "dead".to_string(),
            ..before_hash.clone()
        };
        assert!(!process_remained_ready_after_hash(
            &before_hash,
            &stopped,
            "digest",
            "digest"
        ));
    }
}
