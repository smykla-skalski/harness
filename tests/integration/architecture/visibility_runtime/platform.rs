use super::*;

#[test]
fn platform_runtime_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let runtime = fs::read_to_string(root.join("src/platform/runtime.rs")).unwrap();

    for needle in [
        "pub struct ControlPlaneAccess<'a>",
        "pub struct KubernetesRuntime<'a>",
        "pub struct UniversalRuntime<'a>",
        "fn universal_runtime_exposes_control_plane_access(",
        "fn profile_platform_detects_universal_variants(",
        "mod tests {",
    ] {
        assert!(
            !runtime.contains(needle),
            "src/platform/runtime.rs should stay focused on production runtime access instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/platform/runtime/tests.rs").exists(),
        "platform runtime split test module should exist"
    );
    for path in [
        "src/platform/runtime/access.rs",
        "src/platform/runtime/kubernetes.rs",
        "src/platform/runtime/universal.rs",
        "src/platform/runtime/profile.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "platform runtime split module should exist: {path}"
        );
    }
}

#[test]
fn platform_ephemeral_metallb_module_is_gone() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    for path in [
        "src/platform/ephemeral_metallb.rs",
        "src/platform/ephemeral_metallb/tests.rs",
    ] {
        assert!(
            !root.join(path).exists(),
            "retired MetalLB template bookkeeping should be gone: {path}"
        );
    }
}

#[test]
fn platform_kubectl_validate_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let kubectl_validate =
        fs::read_to_string(root.join("src/platform/kubectl_validate.rs")).unwrap();

    for needle in [
        "fn state_path_ends_with_expected_segments(",
        "fn resolve_binary_uses_env_override(",
        "mod tests {",
    ] {
        assert!(
            !kubectl_validate.contains(needle),
            "src/platform/kubectl_validate.rs should stay focused on production kubectl-validate state and resolution instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/platform/kubectl_validate/tests.rs").exists(),
        "platform kubectl_validate split test module should exist"
    );
}
