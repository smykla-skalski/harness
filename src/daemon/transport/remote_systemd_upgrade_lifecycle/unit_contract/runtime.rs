use crate::errors::CliError;

use super::super::files::io_error;
use super::super::model::SYSTEMD_START_TIMEOUT;
use super::{require_effective_value, require_exact_directive, required_property};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ServiceType {
    Simple,
    Notify,
}

impl ServiceType {
    fn parse(value: &str, context: &str) -> Result<Self, CliError> {
        match value {
            "simple" => Ok(Self::Simple),
            "notify" => Ok(Self::Notify),
            _ => Err(io_error(format!(
                "{context} systemd Type must be simple or notify, found {value}"
            ))),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Simple => "simple",
            Self::Notify => "notify",
        }
    }
}

pub(super) fn validate_source_runtime_contract(
    directives: &[(String, String)],
) -> Result<ServiceType, CliError> {
    let values = directives
        .iter()
        .filter_map(|(key, value)| (key == "Type").then_some(value.as_str()))
        .collect::<Vec<_>>();
    let [value] = values.as_slice() else {
        return Err(io_error(format!(
            "managed systemd unit requires exactly one Type=simple or Type=notify, found {values:?}"
        )));
    };
    let service_type = ServiceType::parse(value, "managed")?;
    if service_type == ServiceType::Notify {
        require_exact_directive(directives, "NotifyAccess", "main")?;
        require_exact_directive(directives, "TimeoutStartSec", SYSTEMD_START_TIMEOUT)?;
    }
    Ok(service_type)
}

pub(super) fn validate_effective_runtime_contract(
    stdout: &str,
    source_type: ServiceType,
) -> Result<(), CliError> {
    let effective_type = ServiceType::parse(required_property(stdout, "Type")?, "effective")?;
    if effective_type != source_type {
        return Err(io_error(format!(
            "effective systemd Type={} must agree with managed unit Type={}",
            effective_type.as_str(),
            source_type.as_str()
        )));
    }
    if effective_type == ServiceType::Notify {
        require_effective_value(stdout, "NotifyAccess", "main")?;
        require_effective_value(stdout, "TimeoutStartUSec", SYSTEMD_START_TIMEOUT)?;
    }
    Ok(())
}
