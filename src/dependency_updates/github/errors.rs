use crate::errors::CliError;
use crate::github_api_errors;

pub(super) fn client_error(error: octocrab::Error) -> CliError {
    github_api_errors::client_error("create dependency-updates github client", error)
}

pub(super) fn operation_error(error: octocrab::Error) -> CliError {
    github_api_errors::operation_error("dependency-updates github request failed", error)
}
