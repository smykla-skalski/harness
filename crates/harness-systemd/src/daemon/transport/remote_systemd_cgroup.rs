use std::io::ErrorKind;
use std::path::{Component, Path, PathBuf};

use fs_err as fs;

use crate::errors::{CliError, CliErrorKind};

const SYSTEM_CGROUP_ROOT: &str = "/sys/fs/cgroup";

#[derive(Debug)]
pub(super) struct ValidatedControlGroup {
    events_file: PathBuf,
    populated_before_stop: bool,
}

impl ValidatedControlGroup {
    pub(super) fn was_populated(&self) -> bool {
        self.populated_before_stop
    }
}

pub(super) fn cgroup_events_file(control_group: &str) -> Result<PathBuf, CliError> {
    cgroup_events_file_at(Path::new(SYSTEM_CGROUP_ROOT), control_group)
}

pub(super) fn cgroup_events_file_at(
    cgroup_root: &Path,
    control_group: &str,
) -> Result<PathBuf, CliError> {
    let path = Path::new(control_group);
    let relative = path.strip_prefix(Path::new("/")).map_err(|_| {
        io_error(format!(
            "systemd ControlGroup must be absolute, found {control_group}"
        ))
    })?;
    if relative.as_os_str().is_empty()
        || relative
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err(io_error(format!(
            "systemd ControlGroup is not a safe service cgroup: {control_group}"
        )));
    }
    Ok(cgroup_root.join(relative).join("cgroup.events"))
}

pub(super) fn validate_control_group_before_stop(
    events_file: PathBuf,
) -> Result<ValidatedControlGroup, CliError> {
    let contents = fs::read_to_string(&events_file).map_err(|error| {
        io_error(format!(
            "inspect systemd service cgroup events before stop {}: {error}",
            events_file.display()
        ))
    })?;
    let populated_before_stop = parse_cgroup_populated(&events_file, &contents)?;
    Ok(ValidatedControlGroup {
        events_file,
        populated_before_stop,
    })
}

pub(super) fn require_unpopulated_control_group(
    control_group: Option<&ValidatedControlGroup>,
) -> Result<(), CliError> {
    let Some(control_group) = control_group else {
        return Ok(());
    };
    let contents = match fs::read_to_string(&control_group.events_file) {
        Ok(contents) => contents,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(io_error(format!(
                "inspect stopped systemd service cgroup events {}: {error}",
                control_group.events_file.display()
            )));
        }
    };
    if parse_cgroup_populated(&control_group.events_file, &contents)? {
        Err(io_error(format!(
            "systemd service cgroup subtree remains populated after stop: {}",
            control_group.events_file.display()
        )))
    } else {
        Ok(())
    }
}

fn parse_cgroup_populated(events_file: &Path, contents: &str) -> Result<bool, CliError> {
    let mut populated = None;
    for line in contents.lines() {
        let mut fields = line.split_whitespace();
        let Some(key) = fields.next() else {
            return Err(malformed_cgroup_events(events_file, line));
        };
        let Some(value) = fields.next() else {
            return Err(malformed_cgroup_events(events_file, line));
        };
        if fields.next().is_some() {
            return Err(malformed_cgroup_events(events_file, line));
        }
        if key == "populated" && populated.replace(value).is_some() {
            return Err(io_error(format!(
                "systemd service cgroup events contains duplicate populated evidence: {}",
                events_file.display()
            )));
        }
    }

    match populated {
        Some("0") => Ok(false),
        Some("1") => Ok(true),
        Some(value) => Err(io_error(format!(
            "systemd service cgroup events has invalid populated value {value:?}: {}",
            events_file.display()
        ))),
        None => Err(io_error(format!(
            "systemd service cgroup events omitted populated evidence: {}",
            events_file.display()
        ))),
    }
}

fn malformed_cgroup_events(events_file: &Path, line: &str) -> CliError {
    io_error(format!(
        "systemd service cgroup events is malformed at {line:?}: {}",
        events_file.display()
    ))
}

fn io_error(message: impl Into<String>) -> CliError {
    CliErrorKind::workflow_io(message.into()).into()
}
