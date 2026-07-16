use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};

const SERVICE_SUFFIX: &str = ".service";
const RECOVERY_UNIT_SUFFIX: &str = "-harness-recovery";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::daemon::transport) struct CanonicalRemoteSystemdUnit(String);

impl CanonicalRemoteSystemdUnit {
    pub(in crate::daemon::transport) fn parse(input: &str) -> Result<Self, CliError> {
        let unit = input.strip_suffix(SERVICE_SUFFIX).unwrap_or(input);
        validate_canonical_unit_name(unit)?;
        Ok(Self(unit.to_string()))
    }

    pub(in crate::daemon::transport) fn from_canonical(unit: &str) -> Result<Self, CliError> {
        validate_canonical_unit_name(unit)?;
        Ok(Self(unit.to_string()))
    }

    pub(in crate::daemon::transport) fn as_str(&self) -> &str {
        &self.0
    }

    pub(in crate::daemon::transport) fn into_string(self) -> String {
        self.0
    }

    pub(in crate::daemon::transport) fn service_name(&self) -> String {
        unit_service_name(self.as_str())
    }

    pub(in crate::daemon::transport) fn unit_path(&self, root: &Path) -> PathBuf {
        root.join(self.service_name())
    }

    pub(in crate::daemon::transport) fn environment_path(&self, root: &Path) -> PathBuf {
        root.join(format!("{}.env", self.as_str()))
    }

    pub(in crate::daemon::transport) fn child_path(&self, root: &Path) -> PathBuf {
        root.join(self.as_str())
    }
}

pub(in crate::daemon::transport) fn unit_service_name(unit: &str) -> String {
    format!("{unit}{SERVICE_SUFFIX}")
}

pub(in crate::daemon::transport) fn parse_remote_systemd_unit_arg(
    input: &str,
) -> Result<String, String> {
    CanonicalRemoteSystemdUnit::parse(input)
        .map(CanonicalRemoteSystemdUnit::into_string)
        .map_err(|error| error.to_string())
}

pub(in crate::daemon::transport) fn validate_canonical_unit_name(
    unit: &str,
) -> Result<(), CliError> {
    if !unit.is_empty()
        && unit != "."
        && !unit.starts_with('-')
        && !unit.starts_with('.')
        && !unit.ends_with('.')
        && !unit.ends_with(SERVICE_SUFFIX)
        && !unit.ends_with(RECOVERY_UNIT_SUFFIX)
        && !unit.contains('/')
        && !unit.contains('\\')
        && !unit.contains("..")
        && unit.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.')
        })
    {
        return Ok(());
    }
    Err(
        CliErrorKind::workflow_parse(format!("unsafe or noncanonical systemd unit name '{unit}'"))
            .into(),
    )
}

pub(in crate::daemon::transport) fn validate_path_outside_unit_directory(
    label: &str,
    path: &Path,
    root: &Path,
    unit: &str,
) -> Result<(), CliError> {
    let unit_directory = root.join(unit);
    if path.starts_with(&unit_directory) {
        return Err(CliErrorKind::workflow_parse(format!(
            "systemd {label} path must be outside DynamicUser state directory {}: {}",
            unit_directory.display(),
            path.display()
        ))
        .into());
    }
    Ok(())
}

pub(in crate::daemon::transport) fn validate_systemd_directive_path(
    label: &str,
    path: &Path,
) -> Result<(), CliError> {
    let rendered = path.as_os_str().to_string_lossy();
    if !path.is_absolute() {
        return Err(CliErrorKind::workflow_parse(format!(
            "systemd {label} path must be absolute: {}",
            path.display()
        ))
        .into());
    }
    if rendered
        .split('/')
        .any(|component| matches!(component, "." | ".."))
    {
        return Err(CliErrorKind::workflow_parse(format!(
            "systemd {label} path must not contain '.' or '..': {}",
            path.display()
        ))
        .into());
    }
    if rendered.chars().any(char::is_whitespace) {
        return Err(CliErrorKind::workflow_parse(format!(
            "systemd {label} path contains whitespace: {}",
            path.display()
        ))
        .into());
    }
    if rendered.contains('%') {
        return Err(CliErrorKind::workflow_parse(format!(
            "systemd {label} path cannot contain '%': {}",
            path.display()
        ))
        .into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::{CanonicalRemoteSystemdUnit, validate_systemd_directive_path};

    #[test]
    fn accepts_bare_or_exactly_one_service_suffix() {
        let bare = CanonicalRemoteSystemdUnit::parse("harness-remote").expect("bare unit");
        let suffixed =
            CanonicalRemoteSystemdUnit::parse("harness-remote.service").expect("suffixed unit");

        assert_eq!(bare, suffixed);
        assert_eq!(bare.as_str(), "harness-remote");
        assert_eq!(bare.service_name(), "harness-remote.service");
    }

    #[test]
    fn rejects_noncanonical_and_path_colliding_spellings() {
        for unit in [
            "",
            ".",
            ".service",
            "..service",
            ".hidden",
            "trailing.",
            "harness..remote",
            "harness-remote.service.service",
            "harness-remote.service.",
            "harness-remote-harness-recovery",
            "harness-remote-harness-recovery.service",
            "../harness-remote",
            "-harness-remote",
        ] {
            assert!(
                CanonicalRemoteSystemdUnit::parse(unit).is_err(),
                "accepted noncanonical unit {unit:?}"
            );
        }
    }

    #[test]
    fn accepted_cli_spellings_derive_identical_paths() {
        let bare = paths("harness-remote");
        let suffixed = paths("harness-remote.service");

        assert_eq!(bare, suffixed);
        assert_eq!(
            bare,
            (
                "/etc/systemd/system/harness-remote.service".into(),
                "/etc/harness/harness-remote.env".into(),
                "/var/lib/harness/remote-systemd/harness-remote".into(),
                "/var/lib/private/harness-remote".into(),
            )
        );
    }

    #[test]
    fn directive_paths_reject_non_normalized_components() {
        for path in [
            "relative.env",
            "/etc/harness/./remote.env",
            "/etc/harness/../remote.env",
        ] {
            assert!(
                validate_systemd_directive_path("environment", Path::new(path)).is_err(),
                "accepted unsafe directive path {path:?}"
            );
        }
    }

    fn paths(input: &str) -> (String, String, String, String) {
        let unit = CanonicalRemoteSystemdUnit::parse(input).expect("canonical unit");
        (
            unit.unit_path(Path::new("/etc/systemd/system"))
                .display()
                .to_string(),
            unit.environment_path(Path::new("/etc/harness"))
                .display()
                .to_string(),
            unit.child_path(Path::new("/var/lib/harness/remote-systemd"))
                .display()
                .to_string(),
            unit.child_path(Path::new("/var/lib/private"))
                .display()
                .to_string(),
        )
    }
}
