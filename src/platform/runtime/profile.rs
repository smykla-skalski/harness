#[cfg(test)]
use crate::kernel::topology::Platform;

/// Resolve a run profile to a runtime platform when no cluster spec exists yet.
#[must_use]
#[cfg(test)]
pub fn profile_platform(profile: &str) -> Platform {
    if profile == "universal" || profile.starts_with("universal-") {
        return Platform::Universal;
    }
    Platform::Kubernetes
}
