use serde::{Deserialize, Serialize};

use crate::errors::CliError;

use super::super::files::io_error;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub(in super::super) struct DatabaseSeal {
    pub(in super::super) present: bool,
    pub(in super::super) schema: Option<i64>,
}

impl DatabaseSeal {
    #[must_use]
    pub(in super::super) const fn new(present: bool, schema: Option<i64>) -> Self {
        Self { present, schema }
    }

    pub(in super::super) fn validate(self) -> Result<(), CliError> {
        if !self.present && self.schema.is_some() {
            Err(io_error(
                "absent systemd database seal cannot record a schema version",
            ))
        } else {
            Ok(())
        }
    }
}
