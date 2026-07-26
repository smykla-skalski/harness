use std::collections::HashMap;
use std::env;

/// Merge current env with extra key-value pairs.
///
/// `PATH` gets no special treatment: it is inherited from the current process,
/// stays absent when the process has none, and is overridable through `extra`
/// like any other key. A previous version prepended a repo-local build-artifacts
/// directory to it, which silently changed binary resolution for every command
/// harness spawns.
#[must_use]
pub fn merge_env<'a, I>(extra: I) -> HashMap<String, String>
where
    I: IntoIterator<Item = (&'a String, &'a String)>,
{
    let mut merged: HashMap<String, String> = env::vars().collect();
    merged.extend(
        extra
            .into_iter()
            .map(|(key, value)| (key.clone(), value.clone())),
    );
    merged
}

#[cfg(test)]
#[path = "environment/tests.rs"]
mod tests;
