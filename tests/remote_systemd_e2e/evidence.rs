use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use serde_json::Value;

use super::candidates::{CORRUPTION_MARKER_NAME, CORRUPTION_MARKER_VALUE};
use super::systemd_assertions::{assert_private_root_directory, root_path_matches};

pub(super) fn recovery_arm_phase(transaction_path: &Path) -> Result<Option<String>, String> {
    Ok(recovery_arm(transaction_path)?.and_then(|arm| arm["phase"].as_str().map(str::to_string)))
}

pub(super) fn recovery_transaction_id(transaction_path: &Path) -> Result<String, String> {
    recovery_arm(transaction_path)?
        .and_then(|arm| arm["transaction_id"].as_str().map(str::to_string))
        .ok_or_else(|| {
            format!(
                "recovery arm {} omitted transaction_id",
                transaction_path.join("armed.json").display()
            )
        })
}

pub(super) fn assert_target_database_seal_persisted(transaction_path: &Path) -> Result<(), String> {
    let arm = recovery_arm(transaction_path)?.ok_or_else(|| {
        format!(
            "recovery arm {} is absent",
            transaction_path.join("armed.json").display()
        )
    })?;
    let seal = &arm["target_database_seal"];
    let present = seal["present"].as_bool();
    let schema = &seal["schema"];
    if present == Some(true) && (schema.is_null() || schema.is_i64()) {
        Ok(())
    } else {
        Err(format!(
            "recovery arm has no persisted target database seal: {arm}"
        ))
    }
}

pub(super) fn failed_current_path(transaction_path: &Path, transaction_id: &str) -> PathBuf {
    transaction_path.join(format!("failed-current-{transaction_id}"))
}

pub(super) fn assert_corrupt_rollback_evidence(
    transaction_path: &Path,
    state_path: &Path,
    service: &str,
    report: &Value,
) -> Result<(), String> {
    let marker_path = state_path.join("harness").join(CORRUPTION_MARKER_NAME);
    let mut journal = sudo(["journalctl", "--no-pager", "-n", "200", "-u"]);
    journal.arg(service);
    let journal = checked(journal, "read failed-candidate systemd journal")?;
    let journal = String::from_utf8_lossy(&journal.stdout);
    if !journal.contains(CORRUPTION_MARKER_VALUE) {
        return Err(format!(
            "failed candidate journal omitted durable database corruption marker: {journal}"
        ));
    }
    if root_path_matches("-e", &marker_path)? {
        return Err(format!(
            "automatic rollback left database corruption marker {} behind",
            marker_path.display()
        ));
    }
    let transaction_id = report["transaction_id"]
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("automatic rollback report omitted transaction_id: {report}"))?;
    let evidence_path = failed_current_path(transaction_path, transaction_id);
    if !root_path_matches("-d", &evidence_path)? {
        return Err(format!(
            "automatic rollback omitted failed-current evidence {}",
            evidence_path.display()
        ));
    }
    assert_private_root_directory(transaction_path, "systemd transaction store")?;
    assert_corrupt_candidate_evidence(&evidence_path)
}

pub(super) fn assert_corrupt_candidate_evidence(evidence_path: &Path) -> Result<(), String> {
    assert_private_root_directory(evidence_path, "failed-current rollback evidence")?;
    let marker_path = evidence_path.join(CORRUPTION_MARKER_NAME);
    let marker = root_file_contents(&marker_path, "failed-current corruption marker")?;
    if marker.trim() != CORRUPTION_MARKER_VALUE {
        return Err(format!(
            "failed-current corruption marker was {:?}, expected {:?}",
            marker.trim(),
            CORRUPTION_MARKER_VALUE
        ));
    }
    let database = evidence_path.join("daemon/external/harness.db");
    let contents = root_file_contents(&database, "failed-current corrupted database")?;
    if contents == "candidate-corrupted-database\n" {
        Ok(())
    } else {
        Err(format!(
            "failed-current database omitted candidate corruption: {contents:?}"
        ))
    }
}

fn recovery_arm(transaction_path: &Path) -> Result<Option<Value>, String> {
    let path = transaction_path.join("armed.json");
    if !root_path_matches("-f", &path)? {
        return Ok(None);
    }
    let output = checked(
        sudo([OsStr::new("cat"), path.as_os_str()]),
        "read recovery arm",
    )?;
    serde_json::from_slice(&output.stdout)
        .map(Some)
        .map_err(|error| format!("decode recovery arm {}: {error}", path.display()))
}

fn root_file_contents(path: &Path, label: &str) -> Result<String, String> {
    let output = checked(
        sudo([OsStr::new("cat"), path.as_os_str()]),
        &format!("read {label}"),
    )?;
    String::from_utf8(output.stdout).map_err(|error| format!("decode {label}: {error}"))
}

fn checked(mut command: Command, action: &str) -> Result<Output, String> {
    command.env("LC_ALL", "C");
    let output = command
        .output()
        .map_err(|error| format!("{action}: {error}"))?;
    if output.status.success() {
        Ok(output)
    } else {
        Err(format!(
            "{action} exited with {}; stdout={}; stderr={}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ))
    }
}

fn sudo<I, S>(args: I) -> Command
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let mut command = Command::new("sudo");
    command.arg("-n").args(args);
    command
}
