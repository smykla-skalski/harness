use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use crate::errors::CliError;

use super::super::remote_systemd_cgroup::{
    ValidatedControlGroup, cgroup_events_file, require_unpopulated_control_group,
    validate_control_group_before_stop,
};
use super::super::remote_systemd_inhibitor::{install_inhibitor, remove_inhibitor};
use super::super::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use super::super::remote_systemd_start_permit::{
    install_runtime_start_permit, remove_stale_runtime_start_permit,
    require_runtime_start_permit_absent,
};
use super::files::{combine_errors, combine_results, io_error};
use super::model::{RemoteSystemdHealthReport, RemoteSystemdOperationPlan, SystemdObservation};
use super::systemd_reset::reset_failed_units;
use super::unit_contract::{
    validate_inhibited_managed_unit_contract, validate_managed_unit_contract,
    validate_managed_unit_source_contract, validate_permitted_managed_unit_contract,
};

#[cfg(feature = "remote-systemd-e2e-faults")]
#[path = "systemd/e2e_crash_boundary.rs"]
mod e2e_crash_boundary;
#[path = "systemd/health.rs"]
mod health;
#[path = "systemd/process_environment.rs"]
mod process_environment;
#[path = "systemd/unit_upgrade.rs"]
mod unit_upgrade;

pub(crate) use health::verify_remote_systemd_health;

#[cfg(test)]
pub(crate) use health::{restart_stability_behavior_for_tests, stability_reset_sequence_for_tests};

pub(crate) fn unit_requires_notify_upgrade(path: &Path) -> Result<bool, CliError> {
    unit_upgrade::unit_requires_notify_upgrade(path)
}

pub(super) fn upgrade_unit_to_notify(path: &Path) -> Result<(), CliError> {
    unit_upgrade::upgrade_unit_to_notify(path)
}

#[cfg(test)]
pub(crate) fn notify_unit_contents_for_tests(contents: &str) -> Result<String, CliError> {
    unit_upgrade::notify_unit_contents_for_tests(contents)
}

#[cfg(test)]
#[path = "systemd/tests.rs"]
mod tests;

pub(super) fn stop_for_restore<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    stop_and_inhibit(plan, run_systemctl)
}

pub(super) fn stop_and_inhibit<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    prepare_inhibitor_on_disk(plan)?;
    let loaded = load_inhibitor(plan, run_systemctl);
    let quiesced = quiesce_service(plan, run_systemctl);
    combine_results("load systemd inhibitor before quiescence", loaded, quiesced)
}

fn prepare_inhibitor_on_disk(plan: &RemoteSystemdOperationPlan) -> Result<(), CliError> {
    install_inhibitor(&plan.unit_path)?;
    remove_stale_runtime_start_permit(&plan.unit_path)?;
    require_runtime_start_permit_absent(&plan.unit_path)
}

fn quiesce_service<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let control_group = observe_stop_control_group(plan, run_systemctl)?;
    let stopped = systemctl_checked(run_systemctl, &["stop".to_string(), plan.service()]);
    let inactive = require_stopped_service(plan, run_systemctl);
    let empty = require_unpopulated_control_group(control_group.as_ref());
    let quiescence = combine_results("prove stopped systemd service", inactive, empty);
    combine_results("stop systemd service", stopped, quiescence)
}

fn load_inhibitor<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    systemctl_checked(run_systemctl, &["daemon-reload".to_string()])?;
    validate_inhibited_managed_unit_contract(plan, run_systemctl)
}

fn observe_stop_control_group<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
) -> Result<Option<ValidatedControlGroup>, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let output = systemctl_checked_output(
        run_systemctl,
        &[
            "show".to_string(),
            "--property=ActiveState".to_string(),
            "--property=SubState".to_string(),
            "--property=MainPID".to_string(),
            "--property=NRestarts".to_string(),
            "--property=ControlGroup".to_string(),
            plan.service(),
        ],
    )?;
    let observation = parse_systemd_observation(&output.stdout)?;
    let control_group = property(&output.stdout, "ControlGroup")
        .ok_or_else(|| io_error("systemctl show omitted ControlGroup"))?;
    if control_group.is_empty() {
        if observation.active_state == "active" || observation.main_pid > 0 {
            return Err(io_error(format!(
                "{} is active without an effective systemd ControlGroup",
                plan.service()
            )));
        }
        return Ok(None);
    }
    let events_file = observed_cgroup_events_file(&output.stdout, control_group)?;
    let validated = validate_control_group_before_stop(events_file)?;
    if (observation.active_state == "active" || observation.main_pid > 0)
        && !validated.was_populated()
    {
        return Err(io_error(format!(
            "{} may be running but its recursive systemd cgroup is unpopulated",
            plan.service()
        )));
    }
    Ok(Some(validated))
}

#[cfg(not(test))]
fn observed_cgroup_events_file(_stdout: &str, control_group: &str) -> Result<PathBuf, CliError> {
    cgroup_events_file(control_group)
}

#[cfg(test)]
fn observed_cgroup_events_file(stdout: &str, control_group: &str) -> Result<PathBuf, CliError> {
    property(stdout, "HarnessTestControlGroupEvents").map_or_else(
        || cgroup_events_file(control_group),
        |path| Ok(PathBuf::from(path)),
    )
}

pub(super) fn start_and_verify<RunSystemctl, VerifyHealth>(
    plan: &RemoteSystemdOperationPlan,
    expected_sha256: &str,
    run_systemctl: &RunSystemctl,
    verify_health: &VerifyHealth,
) -> Result<RemoteSystemdHealthReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    VerifyHealth: Fn(
        &RemoteSystemdOperationPlan,
        &str,
        &RunSystemctl,
    ) -> Result<RemoteSystemdHealthReport, CliError>,
{
    validate_managed_unit_source_contract(plan)?;
    if let Err(error) = start_with_inhibitor_guard(plan, run_systemctl) {
        let inhibited = stop_and_inhibit(plan, run_systemctl);
        return Err(combine_errors(
            "prepare and start systemd generation",
            &error,
            inhibited.err(),
        ));
    }
    match verify_health(plan, expected_sha256, run_systemctl) {
        Ok(health) => Ok(health),
        Err(error) => {
            let inhibited = stop_and_inhibit(plan, run_systemctl);
            Err(combine_errors(
                "verify started systemd generation",
                &error,
                inhibited.err(),
            ))
        }
    }
}

fn start_with_inhibitor_guard<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    install_inhibitor(&plan.unit_path)?;
    let permit = install_runtime_start_permit(&plan.unit_path)?;
    systemctl_checked(run_systemctl, &["daemon-reload".to_string()])?;
    validate_permitted_managed_unit_contract(plan, &permit, run_systemctl)?;
    #[cfg(feature = "remote-systemd-e2e-faults")]
    e2e_crash_boundary::pause_at(e2e_crash_boundary::StartBoundary::PermitReloaded)?;
    reset_failed_units(&[plan.service()], run_systemctl)?;
    systemctl_checked(
        run_systemctl,
        &[
            "start".to_string(),
            "--no-block".to_string(),
            plan.service(),
        ],
    )?;
    wait_for_spawned_service(plan, run_systemctl)?;
    #[cfg(feature = "remote-systemd-e2e-faults")]
    e2e_crash_boundary::pause_at(e2e_crash_boundary::StartBoundary::ServiceSpawned)?;
    permit.remove()?;
    #[cfg(feature = "remote-systemd-e2e-faults")]
    e2e_crash_boundary::pause_at(e2e_crash_boundary::StartBoundary::PermitRemoved)?;
    systemctl_checked(run_systemctl, &["daemon-reload".to_string()])?;
    validate_inhibited_managed_unit_contract(plan, run_systemctl)
}

pub(super) fn release_inhibitor<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    require_runtime_start_permit_absent(&plan.unit_path)?;
    remove_inhibitor(&plan.unit_path)?;
    systemctl_checked(run_systemctl, &["daemon-reload".to_string()])?;
    validate_managed_unit_contract(plan, run_systemctl)
}

fn wait_for_spawned_service<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let started = Instant::now();
    loop {
        let observation = observe_systemd(plan, run_systemctl)?;
        if observation.main_pid > 0
            && matches!(observation.active_state.as_str(), "active" | "activating")
        {
            return Ok(());
        }
        if started.elapsed() >= plan.readiness_timeout {
            return Err(io_error(format!(
                "{} did not spawn before its inhibitor was reloaded (ActiveState={}, SubState={}, MainPID={})",
                plan.service(),
                observation.active_state,
                observation.sub_state,
                observation.main_pid,
            )));
        }
        thread::sleep(Duration::from_millis(25));
    }
}

pub(super) fn require_stopped_service<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let observation = observe_systemd(plan, run_systemctl)?;
    if observation.main_pid == 0 && observation.active_state != "active" {
        Ok(())
    } else {
        Err(io_error(format!(
            "{} did not stop cleanly (ActiveState={}, MainPID={})",
            plan.service(),
            observation.active_state,
            observation.main_pid
        )))
    }
}

pub(super) fn observe_systemd<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
) -> Result<SystemdObservation, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let output = systemctl_checked_output(
        run_systemctl,
        &[
            "show".to_string(),
            "--property=ActiveState".to_string(),
            "--property=SubState".to_string(),
            "--property=MainPID".to_string(),
            "--property=NRestarts".to_string(),
            plan.service(),
        ],
    )?;
    parse_systemd_observation(&output.stdout)
}

fn parse_systemd_observation(stdout: &str) -> Result<SystemdObservation, CliError> {
    let mut active_state = None;
    let mut sub_state = None;
    let mut main_pid = None;
    let mut n_restarts = None;
    for line in stdout.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key {
            "ActiveState" => active_state = Some(value.to_string()),
            "SubState" => sub_state = Some(value.to_string()),
            "MainPID" => main_pid = value.parse::<u32>().ok(),
            "NRestarts" => n_restarts = value.parse::<u64>().ok(),
            _ => {}
        }
    }
    Ok(SystemdObservation {
        active_state: active_state.ok_or_else(|| io_error("systemctl show omitted ActiveState"))?,
        sub_state: sub_state.ok_or_else(|| io_error("systemctl show omitted SubState"))?,
        main_pid: main_pid.ok_or_else(|| io_error("systemctl show omitted MainPID"))?,
        n_restarts: n_restarts.ok_or_else(|| io_error("systemctl show omitted NRestarts"))?,
    })
}

fn property<'a>(stdout: &'a str, key: &str) -> Option<&'a str> {
    stdout
        .lines()
        .find_map(|line| line.split_once('=').filter(|(name, _)| *name == key))
        .map(|(_, value)| value)
}

pub(super) fn systemctl_checked<RunSystemctl>(
    run_systemctl: &RunSystemctl,
    args: &[String],
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    systemctl_checked_output(run_systemctl, args).map(|_| ())
}

fn systemctl_checked_output<RunSystemctl>(
    run_systemctl: &RunSystemctl,
    args: &[String],
) -> Result<RemoteSystemdCommandOutput, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let output = run_systemctl(args)?;
    if output.exit_code == 0 {
        Ok(output)
    } else {
        Err(io_error(format!(
            "systemctl {} failed with exit code {}: {}",
            shell_words::join(args.iter().map(String::as_str)),
            output.exit_code,
            output.stderr.trim()
        )))
    }
}

#[cfg(test)]
pub(crate) fn parse_systemd_observation_for_tests(
    stdout: &str,
) -> Result<(String, String, u32, u64), CliError> {
    let observation = parse_systemd_observation(stdout)?;
    Ok((
        observation.active_state,
        observation.sub_state,
        observation.main_pid,
        observation.n_restarts,
    ))
}
