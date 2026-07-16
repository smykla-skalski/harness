use std::path::PathBuf;

use crate::errors::{CliError, CliErrorKind};

const SERVICE_SUFFIX: &str = ".service";
const RECOVERY_UNIT_SUFFIX: &str = "-harness-recovery";

pub(super) fn daemon_root(input: &str) -> Result<PathBuf, CliError> {
    if !cfg!(target_os = "linux") {
        return Err(CliErrorKind::workflow_io(
            "remote daemon systemd state requires Linux".to_string(),
        )
        .into());
    }
    let unit = canonical_unit(input)?;
    Ok(PathBuf::from("/var/lib/private")
        .join(unit)
        .join("harness")
        .join("daemon")
        .join("external"))
}

fn canonical_unit(input: &str) -> Result<&str, CliError> {
    let unit = input.strip_suffix(SERVICE_SUFFIX).unwrap_or(input);
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
        return Ok(unit);
    }
    Err(CliErrorKind::workflow_parse(format!(
        "unsafe or noncanonical systemd unit name '{input}'"
    ))
    .into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_unit_matches_lifecycle_contract() {
        assert_eq!(
            canonical_unit("harness-remote.service").expect("service suffix"),
            "harness-remote"
        );
        assert_eq!(
            canonical_unit("harness_remote.2").expect("canonical unit"),
            "harness_remote.2"
        );
        for invalid in [
            "",
            ".",
            ".hidden",
            "-leading",
            "trailing.",
            "instance@",
            "nested/unit",
            "double..dot",
            "unit.service.service",
            "unit-harness-recovery",
        ] {
            assert!(canonical_unit(invalid).is_err(), "accepted {invalid:?}");
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn daemon_root_uses_canonical_unit() {
        assert_eq!(
            daemon_root("harness-remote.service").expect("daemon root"),
            PathBuf::from("/var/lib/private/harness-remote/harness/daemon/external")
        );
    }
}
