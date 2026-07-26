use std::borrow::Cow;
use std::path::Path;

use super::GuardContext;

impl GuardContext {
    #[must_use]
    pub fn effective_run_dir(&self) -> Option<Cow<'_, Path>> {
        self.run_dir.as_deref().map(Cow::Borrowed)
    }
}
