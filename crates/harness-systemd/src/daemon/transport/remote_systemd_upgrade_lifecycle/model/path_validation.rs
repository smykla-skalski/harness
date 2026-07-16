use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};

use super::RemoteSystemdOperationPlan;

pub(super) fn validate_non_overlapping_paths(
    plan: &RemoteSystemdOperationPlan,
) -> Result<(), CliError> {
    validate_state_and_store(plan)?;
    let state_directory = plan.state_path.parent().ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_parse(
            "systemd state path has no StateDirectory parent".to_string(),
        ))
    })?;
    let external_paths = external_operation_paths(plan)?;
    validate_external_paths(&external_paths, state_directory, &plan.store_path)?;
    validate_distinct_paths(&external_paths)?;
    validate_controller_source(plan, &external_paths)?;
    validate_store_artifacts(plan)
}

fn validate_state_and_store(plan: &RemoteSystemdOperationPlan) -> Result<(), CliError> {
    if plan.state_path == Path::new("/") || plan.store_path == Path::new("/") {
        return Err(parse_error(
            "systemd state and transaction store paths must not be filesystem root",
        ));
    }
    if paths_overlap(&plan.state_path, &plan.store_path) {
        return Err(parse_error(format!(
            "systemd state and transaction store paths must not overlap: {} and {}",
            plan.state_path.display(),
            plan.store_path.display()
        )));
    }
    let state_directory = plan
        .state_path
        .parent()
        .ok_or_else(|| parse_error("systemd state path has no StateDirectory parent"))?;
    if paths_overlap(&plan.store_path, state_directory) {
        return Err(parse_error(format!(
            "systemd transaction store must be outside StateDirectory {}: {}",
            state_directory.display(),
            plan.store_path.display()
        )));
    }
    Ok(())
}

fn external_operation_paths(
    plan: &RemoteSystemdOperationPlan,
) -> Result<Vec<(&'static str, PathBuf)>, CliError> {
    Ok(vec![
        ("installed binary", plan.binary_path.clone()),
        ("systemd unit", plan.unit_path.clone()),
        ("systemd environment", plan.environment_path.clone()),
        ("systemd recovery service", plan.recovery_service_path()),
        ("systemd recovery timer", plan.recovery_timer_path()),
        ("binary byte reserve", plan.binary_reserve_path()?),
        ("binary inode reserve", plan.binary_inode_reserve_path()?),
    ])
}

fn validate_external_paths(
    paths: &[(&str, PathBuf)],
    state_directory: &Path,
    store_path: &Path,
) -> Result<(), CliError> {
    for (label, path) in paths {
        if path == Path::new("/")
            || paths_overlap(path, state_directory)
            || paths_overlap(path, store_path)
        {
            return Err(parse_error(format!(
                "{label} path must be outside StateDirectory and transaction storage: {}",
                path.display()
            )));
        }
    }
    Ok(())
}

fn validate_distinct_paths(paths: &[(&str, PathBuf)]) -> Result<(), CliError> {
    for (index, (label, path)) in paths.iter().enumerate() {
        for (other_label, other_path) in &paths[index + 1..] {
            if paths_overlap(path, other_path) {
                return Err(parse_error(format!(
                    "{label} and {other_label} paths must be distinct and non-overlapping: {} and {}",
                    path.display(),
                    other_path.display()
                )));
            }
        }
    }
    Ok(())
}

fn validate_controller_source(
    plan: &RemoteSystemdOperationPlan,
    external_paths: &[(&str, PathBuf)],
) -> Result<(), CliError> {
    if plan.controller_path == plan.binary_path {
        return Ok(());
    }
    for (label, path) in external_paths {
        if paths_overlap(&plan.controller_path, path) {
            return Err(parse_error(format!(
                "systemd recovery controller source and {label} paths must not overlap: {} and {}",
                plan.controller_path.display(),
                path.display()
            )));
        }
    }
    let state_directory = plan
        .state_path
        .parent()
        .ok_or_else(|| parse_error("systemd state path has no StateDirectory parent"))?;
    if paths_overlap(&plan.controller_path, &plan.store_path)
        || paths_overlap(&plan.controller_path, state_directory)
    {
        return Err(parse_error(format!(
            "systemd recovery controller source must be outside state and transaction storage: {}",
            plan.controller_path.display()
        )));
    }
    Ok(())
}

fn validate_store_artifacts(plan: &RemoteSystemdOperationPlan) -> Result<(), CliError> {
    let artifacts = [
        ("recovery controller", plan.recovery_controller_path()),
        ("recovery arm", plan.recovery_arm_path()),
        ("state byte reserve", plan.state_reserve_path()),
        ("state inode reserve", plan.state_inode_reserve_path()),
    ];
    validate_distinct_paths(&artifacts)
}

fn paths_overlap(left: &Path, right: &Path) -> bool {
    left.starts_with(right) || right.starts_with(left)
}

fn parse_error(message: impl Into<String>) -> CliError {
    CliErrorKind::workflow_parse(message.into()).into()
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tempfile::tempdir;

    use super::*;

    #[test]
    fn generated_recovery_units_cannot_replace_custom_managed_files() {
        let temp = tempdir().expect("temporary directory");
        let plan = test_plan(temp.path());
        for (label, collision) in [
            ("unit", plan.recovery_service_path()),
            ("environment", plan.recovery_timer_path()),
            (
                "environment",
                plan.binary_reserve_path().expect("reserve path"),
            ),
            (
                "environment",
                plan.binary_inode_reserve_path()
                    .expect("inode reserve path"),
            ),
        ] {
            let mut colliding = plan.clone();
            match label {
                "unit" => colliding.unit_path = collision,
                "environment" => colliding.environment_path = collision,
                _ => unreachable!("known collision label"),
            }
            assert!(
                colliding
                    .validate()
                    .expect_err("generated path collision must fail")
                    .to_string()
                    .contains("non-overlapping")
            );
        }
    }

    #[test]
    fn generated_paths_cannot_replace_transaction_store() {
        let temp = tempdir().expect("temporary directory");
        let mut plan = test_plan(temp.path());
        plan.store_path = plan.recovery_service_path();

        let error = plan
            .validate()
            .expect_err("recovery service/store collision must fail");

        assert!(error.to_string().contains("transaction storage"));
    }

    #[test]
    fn installed_binary_cannot_be_its_own_reserve() {
        let temp = tempdir().expect("temporary directory");
        let mut plan = test_plan(temp.path());
        plan.binary_path = temp
            .path()
            .join(format!(".harness-{}-binary-reserve", plan.unit));

        let error = plan
            .validate()
            .expect_err("binary/reserve collision must fail");

        assert!(error.to_string().contains("binary byte reserve"));
    }

    fn test_plan(root: &Path) -> RemoteSystemdOperationPlan {
        RemoteSystemdOperationPlan {
            unit: "harness-remote".to_string(),
            binary_path: root.join("harness"),
            unit_path: root.join("harness-remote.service"),
            environment_path: root.join("harness-remote.env"),
            state_path: root.join("state").join("harness"),
            store_path: root.join("transactions").join("harness-remote"),
            controller_path: root.join("harness"),
            readiness_timeout: Duration::from_secs(1),
            stabilization_window: Duration::ZERO,
        }
    }
}
