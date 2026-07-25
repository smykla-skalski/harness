//! Naming primitives shared by every layer that creates harness-owned resources.

/// Prefix used for harness-owned resources (containers, networks, temp dirs).
pub const HARNESS_PREFIX: &str = "harness-";

/// Trim a value and treat blank as absent.
#[must_use]
pub fn normalize_optional_value(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

/// Canonicalize an `owner/repo` slug to trimmed, lowercase form.
///
/// Returns `None` unless the value has exactly two non-empty segments, so
/// callers use it to validate as well as to normalize.
#[must_use]
pub fn normalize_repository_slug(repository: Option<&str>) -> Option<String> {
    let repository = normalize_optional_value(repository)?;
    let mut parts = repository.split('/');
    let owner = parts.next()?.trim();
    let repo = parts.next()?.trim();
    if owner.is_empty() || repo.is_empty() || parts.next().is_some() {
        return None;
    }
    Some(format!(
        "{}/{}",
        owner.to_ascii_lowercase(),
        repo.to_ascii_lowercase()
    ))
}

#[cfg(test)]
mod tests;
