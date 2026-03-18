use harness::blocks::{BuildSystem, BuildTarget};

/// `name()` returns a non-empty block identifier.
///
/// # Panics
/// Panics if the block name is empty.
pub fn contract_name_is_non_empty(build: &dyn BuildSystem) {
    let name = build.name();
    assert!(!name.is_empty(), "block name should not be empty");
}

/// `denied_binaries()` returns a stable list (no panics, no mutation).
///
/// # Panics
/// Panics if the list changes between calls.
pub fn contract_denied_binaries_is_stable(build: &dyn BuildSystem) {
    let first = build.denied_binaries();
    let second = build.denied_binaries();
    assert_eq!(
        first, second,
        "denied_binaries should be stable across calls"
    );
}

/// `run_target` with a make target returns a result or error (no panic).
pub fn contract_run_target_does_not_panic(build: &dyn BuildSystem) {
    let target = BuildTarget::make("echo-test");
    let _ = build.run_target(&target);
}

/// `run_target_streaming` with a make target returns a result or error (no panic).
pub fn contract_run_target_streaming_does_not_panic(build: &dyn BuildSystem) {
    let target = BuildTarget::make("echo-test");
    let _ = build.run_target_streaming(&target);
}

#[cfg(test)]
mod tests {
    use super::*;
    use harness::blocks::ProcessBuildSystem;

    fn production_build() -> ProcessBuildSystem {
        use harness::blocks::StdProcessExecutor;
        use std::sync::Arc;
        ProcessBuildSystem::new(Arc::new(StdProcessExecutor))
    }

    #[test]
    #[ignore] // needs make on PATH
    fn production_name_is_non_empty() {
        contract_name_is_non_empty(&production_build());
    }

    #[test]
    #[ignore]
    fn production_denied_binaries_is_stable() {
        contract_denied_binaries_is_stable(&production_build());
    }

    #[test]
    #[ignore]
    fn production_run_target_does_not_panic() {
        contract_run_target_does_not_panic(&production_build());
    }
}
