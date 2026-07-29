//! Mirrors the two generic JSON helpers `daemon/db/task_board/mapper.rs`
//! defines (`to_json`/`parse_json`); duplicated rather than shared for the
//! same reason as `support.rs` -- `mapper.rs` is `pub(super)`-scoped inside
//! `harness-daemon` and this crate cannot depend on `harness-daemon`.

use serde::Serialize;
use serde::de::DeserializeOwned;

use harness_kernel::errors::CliError;

use crate::support::db_error;

pub(crate) fn to_json<T: Serialize>(value: &T, context: &str) -> Result<String, CliError> {
    serde_json::to_string(value).map_err(|error| db_error(format!("serialize {context}: {error}")))
}

pub(crate) fn parse_json<T: DeserializeOwned>(value: &str, context: &str) -> Result<T, CliError> {
    serde_json::from_str(value).map_err(|error| db_error(format!("parse {context}: {error}")))
}
