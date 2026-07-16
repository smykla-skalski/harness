use crate::errors::CliError;

pub(super) use super::super::super::systemd_mount_namespace::ALTERNATE_MOUNT_PROPERTIES;
use super::super::files::io_error;

pub(super) fn reject_source_remaps(directives: &[(String, String)]) -> Result<(), CliError> {
    if let Some((key, value)) = directives
        .iter()
        .find(|(key, _)| ALTERNATE_MOUNT_PROPERTIES.contains(&key.as_str()))
    {
        Err(io_error(format!(
            "managed systemd unit must not define alternate filesystem mapping {key}={value}"
        )))
    } else {
        Ok(())
    }
}

pub(super) fn reject_effective_remaps(stdout: &str) -> Result<(), CliError> {
    for key in ALTERNATE_MOUNT_PROPERTIES {
        let values = stdout
            .lines()
            .filter_map(|line| line.split_once('=').filter(|(name, _)| *name == key))
            .map(|(_, value)| value)
            .collect::<Vec<_>>();
        if !matches!(values.as_slice(), [] | [""]) {
            return Err(io_error(format!(
                "effective systemd unit must not define alternate filesystem mapping {key}, found {values:?}"
            )));
        }
    }
    Ok(())
}
