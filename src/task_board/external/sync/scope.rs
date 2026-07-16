use crate::errors::CliError;

pub(super) enum SyncClientError {
    Provider(CliError),
    Local(CliError),
}
