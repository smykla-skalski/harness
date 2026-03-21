use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};

use crate::errors::{CliError, CliErrorKind};

use super::super::CurrentRunPointer;
use super::super::aggregate::RunAggregate;
use super::port::RunRepositoryPort;

/// In-memory run repository for tests. Stores aggregates and pointers without filesystem.
pub struct InMemoryRunRepository {
    aggregates: Mutex<HashMap<PathBuf, RunAggregate>>,
    pointer: Mutex<Option<CurrentRunPointer>>,
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
            pointer: Mutex::new(None),
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

    fn load_current_pointer(&self) -> Result<Option<CurrentRunPointer>, CliError> {
        Ok(self
            .pointer
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone())
    }

    fn save_current_pointer(&self, pointer: &CurrentRunPointer) -> Result<(), CliError> {
        *self.pointer.lock().unwrap_or_else(PoisonError::into_inner) = Some(pointer.clone());
        Ok(())
    }

    fn update_current_pointer(
        &self,
        update: &dyn Fn(&mut CurrentRunPointer),
    ) -> Result<bool, CliError> {
        let mut guard = self.pointer.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(ref mut pointer) = *guard else {
            return Ok(false);
        };
        update(pointer);
        Ok(true)
    }

    fn clear_current_pointer(&self) -> Result<(), CliError> {
        *self.pointer.lock().unwrap_or_else(PoisonError::into_inner) = None;
        Ok(())
    }

    fn load_from_pointer(&self, pointer: CurrentRunPointer) -> Result<RunAggregate, CliError> {
        self.load(&pointer.layout.run_dir())
    }

    fn load_current(&self) -> Result<Option<RunAggregate>, CliError> {
        let Some(pointer) = self.load_current_pointer()? else {
            return Ok(None);
        };
        self.load_from_pointer(pointer).map(Some)
    }

    fn current_run_dir(&self) -> Result<Option<PathBuf>, CliError> {
        let Some(pointer) = self.load_current_pointer()? else {
            return Ok(None);
        };
        Ok(Some(pointer.layout.run_dir()))
    }
}
