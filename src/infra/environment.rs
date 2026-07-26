use std::collections::HashMap;
use std::env;

/// Merge current env with extra key-value pairs.
///
/// `PATH` is inherited verbatim. This used to gain a locally built `kumactl`
/// directory in front, so every spawned command saw a repo-local binary that
/// the product no longer builds or ships.
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
