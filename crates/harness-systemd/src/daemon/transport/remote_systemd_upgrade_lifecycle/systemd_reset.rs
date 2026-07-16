use crate::daemon::transport::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use crate::errors::CliError;

use super::files::io_error;

pub(super) fn reset_failed_units<RunSystemctl>(
    units: &[String],
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    if units.is_empty() {
        return Ok(());
    }
    let mut args = vec!["reset-failed".to_string(), "--".to_string()];
    args.extend_from_slice(units);
    let output = run_systemctl(&args)?;
    if output.exit_code == 0 || reports_only_unloaded_units(units, &output.stderr) {
        Ok(())
    } else {
        Err(io_error(format!(
            "systemctl {} failed with exit code {}: {}",
            shell_words::join(args.iter().map(String::as_str)),
            output.exit_code,
            output.stderr.trim()
        )))
    }
}

fn reports_only_unloaded_units(units: &[String], stderr: &str) -> bool {
    let lines = stderr
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>();
    !lines.is_empty()
        && lines
            .iter()
            .all(|line| units.iter().any(|unit| *line == unloaded_message(unit)))
}

fn unloaded_message(unit: &str) -> String {
    let action = format!("Failed to reset failed state of unit {unit}:");
    let detail = format!("Unit {unit} not loaded.");
    format!("{action} {detail}")
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use crate::daemon::transport::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
    use crate::errors::CliError;

    use super::{reports_only_unloaded_units, reset_failed_units};

    fn output(exit_code: i32, stderr: impl Into<String>) -> RemoteSystemdCommandOutput {
        RemoteSystemdCommandOutput {
            exit_code,
            stdout: String::new(),
            stderr: stderr.into(),
        }
    }

    #[test]
    fn reset_failed_uses_exact_arguments_and_skips_empty_input() {
        let never = |_args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
            panic!("empty reset set must not invoke systemctl")
        };
        reset_failed_units(&[], &never).expect("empty reset set");

        let calls = RefCell::new(Vec::new());
        let run = |args: &[String]| {
            calls.borrow_mut().push(args.to_vec());
            Ok(output(0, ""))
        };
        let units = ["one.service".to_string(), "two.timer".to_string()];
        reset_failed_units(&units, &run).expect("reset requested units");
        assert_eq!(
            calls.into_inner(),
            [vec![
                "reset-failed".to_string(),
                "--".to_string(),
                "one.service".to_string(),
                "two.timer".to_string(),
            ]]
        );
    }

    #[test]
    fn reset_failed_accepts_only_requested_unloaded_failures() {
        let units = ["one.service".to_string(), "two.timer".to_string()];
        let unloaded = |_args: &[String]| {
            Ok(output(
                1,
                "Failed to reset failed state of unit one.service: Unit one.service not loaded.\n",
            ))
        };
        reset_failed_units(&units, &unloaded)
            .expect("one requested unit may be unloaded while another resets successfully");

        let mixed = |_args: &[String]| {
            Ok(output(
                1,
                concat!(
                    "Failed to reset failed state of unit one.service: Unit one.service not loaded.\n",
                    "Failed to connect to bus: Permission denied\n"
                ),
            ))
        };
        let mixed_result = reset_failed_units(&units, &mixed);
        mixed_result.expect_err("unrelated reset failure must remain fatal");
    }

    #[test]
    fn unloaded_reset_failures_are_safe_for_exact_requested_units() {
        let units = ["one.service".to_string(), "two.timer".to_string()];
        let stderr = concat!(
            "Failed to reset failed state of unit one.service: Unit one.service not loaded.\n",
            "Failed to reset failed state of unit two.timer: Unit two.timer not loaded.\n"
        );
        assert!(reports_only_unloaded_units(&units, stderr));
    }

    #[test]
    fn unrelated_or_unrequested_reset_failures_remain_fatal() {
        let units = ["one.service".to_string()];
        for stderr in [
            "Failed to connect to bus: Permission denied\n",
            "Failed to reset failed state of unit two.service: Unit two.service not loaded.\n",
            "",
        ] {
            assert!(!reports_only_unloaded_units(&units, stderr));
        }
    }
}
