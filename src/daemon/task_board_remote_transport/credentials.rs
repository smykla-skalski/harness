use std::error::Error;
use std::fmt;

#[cfg(target_os = "macos")]
use security_framework::passwords::get_generic_password;

use crate::task_board::TaskBoardExecutionCredentialReference;

#[derive(Clone, PartialEq, Eq)]
pub(super) struct RemoteExecutionCredential(String);

impl fmt::Debug for RemoteExecutionCredential {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_tuple("RemoteExecutionCredential")
            .field(&"<redacted>")
            .finish()
    }
}

impl RemoteExecutionCredential {
    pub(super) fn expose(&self) -> &str {
        &self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RemoteExecutionCredentialError {
    InvalidReference,
    UnsupportedReference,
    MissingCredential,
    InvalidCredential,
    KeychainUnavailable,
}

impl fmt::Display for RemoteExecutionCredentialError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidReference => write!(formatter, "remote credential reference is invalid"),
            Self::UnsupportedReference => {
                write!(
                    formatter,
                    "remote credential reference scheme is unsupported"
                )
            }
            Self::MissingCredential => write!(formatter, "remote execution credential is missing"),
            Self::InvalidCredential => write!(formatter, "remote execution credential is invalid"),
            Self::KeychainUnavailable => {
                write!(
                    formatter,
                    "remote execution Keychain credential is unavailable"
                )
            }
        }
    }
}

impl Error for RemoteExecutionCredentialError {}

#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct RemoteExecutionCredentialResolver;

impl RemoteExecutionCredentialResolver {
    pub(super) fn resolve(
        reference: &str,
    ) -> Result<RemoteExecutionCredential, RemoteExecutionCredentialError> {
        match parse_reference(reference)? {
            TaskBoardExecutionCredentialReference::Environment { name } => {
                let value = std::env::var(&name)
                    .map_err(|_| RemoteExecutionCredentialError::MissingCredential)?;
                validated_credential(value)
            }
            TaskBoardExecutionCredentialReference::Keychain { service, account } => {
                resolve_keychain(&service, &account)
            }
        }
    }
}

fn parse_reference(
    reference: &str,
) -> Result<TaskBoardExecutionCredentialReference, RemoteExecutionCredentialError> {
    if reference.starts_with("op://") || reference.starts_with("secret://") {
        return Err(RemoteExecutionCredentialError::UnsupportedReference);
    }
    TaskBoardExecutionCredentialReference::parse(reference)
        .map_err(|_| RemoteExecutionCredentialError::InvalidReference)
}

fn validated_credential(
    value: String,
) -> Result<RemoteExecutionCredential, RemoteExecutionCredentialError> {
    if value.trim().is_empty() || value.chars().any(char::is_whitespace) {
        return Err(RemoteExecutionCredentialError::InvalidCredential);
    }
    Ok(RemoteExecutionCredential(value))
}

#[cfg(target_os = "macos")]
fn resolve_keychain(
    service: &str,
    account: &str,
) -> Result<RemoteExecutionCredential, RemoteExecutionCredentialError> {
    let bytes = get_generic_password(service, account)
        .map_err(|_| RemoteExecutionCredentialError::KeychainUnavailable)?;
    let value =
        String::from_utf8(bytes).map_err(|_| RemoteExecutionCredentialError::InvalidCredential)?;
    validated_credential(value)
}

#[cfg(not(target_os = "macos"))]
fn resolve_keychain(
    _service: &str,
    _account: &str,
) -> Result<RemoteExecutionCredential, RemoteExecutionCredentialError> {
    Err(RemoteExecutionCredentialError::KeychainUnavailable)
}

#[cfg(test)]
pub(super) fn parse_reference_for_tests(
    reference: &str,
) -> Result<(), RemoteExecutionCredentialError> {
    parse_reference(reference).map(|_| ())
}
