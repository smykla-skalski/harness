use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::errors::CliError;

/// A workflow event with a timestamp.
pub trait WorkflowEvent: std::fmt::Debug {
    fn occurred_at(&self) -> &str;
    fn label(&self) -> &str;
}

/// A transition rule in a state machine.
#[derive(Debug)]
pub struct TransitionRule<Phase: Clone> {
    pub source: Phase,
    pub targets: Vec<Phase>,
    pub event_name: String,
}

/// Error for invalid state transitions.
#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct TransitionError(pub String);

/// Versioned JSON repository with atomic save.
pub struct VersionedJsonRepository {
    path: PathBuf,
    current_version: u32,
}

impl VersionedJsonRepository {
    #[must_use]
    pub fn new(path: PathBuf, current_version: u32) -> Self {
        Self {
            path,
            current_version,
        }
    }

    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Load state from the JSON file.
    ///
    /// # Errors
    /// Returns `CliError` on IO or parse failure.
    pub fn load(&self) -> Result<Option<Value>, CliError> {
        todo!()
    }

    /// Save state to the JSON file atomically.
    ///
    /// # Errors
    /// Returns `CliError` on IO failure.
    pub fn save(&self, _state: &Value) -> Result<(), CliError> {
        todo!()
    }
}

#[cfg(test)]
mod tests {}
