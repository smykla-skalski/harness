use std::borrow::Cow;
use std::path::Path;

use super::GuardContext;

impl GuardContext {
    #[must_use]
    pub fn effective_run_dir(&self) -> Option<Cow<'_, Path>> {
        if let Some(run_directory) = &self.run_dir {
            return Some(Cow::Borrowed(run_directory.as_path()));
        }
        self.run
            .as_ref()
            .map(|run_context| Cow::Owned(run_context.layout.run_dir()))
    }

    #[must_use]
    pub fn suite_dir(&self) -> Option<Cow<'_, Path>> {
        self.run.as_ref().map(|run_context| {
            Path::new(&run_context.metadata.suite_dir)
                .canonicalize()
                .map_or_else(
                    |_| Cow::Borrowed(Path::new(&run_context.metadata.suite_dir)),
                    Cow::Owned,
                )
        })
    }
}
