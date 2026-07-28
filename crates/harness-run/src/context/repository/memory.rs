use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};

use harness_kernel::errors::{CliError, CliErrorKind};

use super::super::aggregate::RunAggregate;
use super::port::RunRepositoryPort;

/// In-memory run repository for tests. Stores aggregates without filesystem.
pub struct InMemoryRunRepository {
    aggregates: Mutex<HashMap<PathBuf, RunAggregate>>,
}

impl Default for InMemoryRunRepository {
    fn default() -> Self {
        Self::new()
    }
}

impl InMemoryRunRepository {
    #[must_use]
    pub fn new() -> Self {
        Self {
            aggregates: Mutex::new(HashMap::new()),
        }
    }

    pub fn insert(&self, run_dir: PathBuf, aggregate: RunAggregate) {
        self.aggregates
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(run_dir, aggregate);
    }
}

impl RunRepositoryPort for InMemoryRunRepository {
    fn load(&self, run_dir: &Path) -> Result<RunAggregate, CliError> {
        self.aggregates
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(run_dir)
            .cloned()
            .ok_or_else(|| CliErrorKind::missing_file(run_dir.display().to_string()).into())
    }
}
