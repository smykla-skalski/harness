use std::env;
use std::fs;
use std::path::PathBuf;

use crate::workspace::harness_data_root;
use crate::errors::{CliError, CliErrorKind};

/// Validate observer setup.
pub(super) fn execute_doctor() -> Result<i32, CliError> {
    let mut failures = 0u32;

    // Check ~/.claude/projects/ exists
    let home = env::var("HOME")
        .map_err(|_| CliErrorKind::session_parse_error("HOME environment variable not set"))?;
    let claude_projects = PathBuf::from(&home).join(".claude").join("projects");
    if claude_projects.is_dir() {
        println!("PASS: ~/.claude/projects/ exists");
    } else {
        println!("FAIL: ~/.claude/projects/ not found");
        failures += 1;
    }

    // Check harness binary
    let harness_path = PathBuf::from(&home).join(".local/bin/harness");
    if harness_path.exists() {
        println!("PASS: ~/.local/bin/harness exists");
    } else {
        println!("FAIL: ~/.local/bin/harness not found");
        failures += 1;
    }

    // Check XDG data directory
    let data_root = harness_data_root();
    if data_root.is_dir() {
        println!("PASS: data directory {} exists", data_root.display());
    } else {
        println!(
            "WARN: data directory {} does not exist yet",
            data_root.display()
        );
    }

    // Check observe state directory is writable
    let observe_dir = data_root.join("observe");
    let _ = fs::create_dir_all(&observe_dir);
    if observe_dir.is_dir() {
        println!("PASS: observe state directory writable");
    } else {
        println!("FAIL: cannot create observe state directory");
        failures += 1;
    }

    if failures > 0 {
        return Err(
            CliErrorKind::session_parse_error(format!("doctor found {failures} failures")).into(),
        );
    }
    Ok(0)
}
