use super::super::helpers::{read_repo_file, repo_path_exists};
use super::*;

#[test]
fn setup_capabilities_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let capabilities = read_repo_file(root, "src/setup/capabilities.rs");

    for needle in [
        "pub enum Feature {",
        "fn core_features()",
        "fn operational_features()",
        "fn capabilities_returns_zero(",
        "fn feature_count_is_current(",
        "mod tests {",
    ] {
        assert!(
            !capabilities.contains(needle),
            "src/setup/capabilities.rs should stay focused on production capability modeling instead of owning `{needle}`"
        );
    }

    assert!(
        repo_path_exists(root, "src/setup/capabilities/tests.rs"),
        "setup capabilities split test module should exist"
    );
    for path in [
        "src/setup/capabilities/model.rs",
        "src/setup/capabilities/data.rs",
        "src/setup/capabilities/readiness.rs",
    ] {
        assert!(
            repo_path_exists(root, path),
            "setup capabilities split module should exist: {path}"
        );
    }
}

#[test]
fn setup_build_info_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let build_info = read_repo_file(root, "src/setup/build_info.rs");

    for needle in ["fn build_info_env(", "mod tests {"] {
        assert!(
            !build_info.contains(needle),
            "src/setup/build_info.rs should stay focused on production build-info resolution instead of owning `{needle}`"
        );
    }

    assert!(
        repo_path_exists(root, "src/setup/build_info/tests.rs"),
        "setup build_info split test module should exist"
    );
}

#[test]
fn setup_gateway_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let gateway = read_repo_file(root, "src/setup/gateway.rs");

    for needle in [
        "fn detect_version_parses_standard_entry()",
        "fn install_url_embeds_arbitrary_version()",
        "mod tests {",
    ] {
        assert!(
            !gateway.contains(needle),
            "src/setup/gateway.rs should stay focused on production gateway setup instead of owning `{needle}`"
        );
    }

    assert!(
        repo_path_exists(root, "src/setup/gateway/tests.rs"),
        "setup gateway split test module should exist"
    );
}

#[test]
fn setup_cluster_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let cluster_mod = read_repo_file(root, "src/setup/cluster/mod.rs");

    for needle in [
        "fn effective_store_uses_cli_arg_for_up(",
        "fn load_persisted_spec_returns_cluster(",
        "mod tests {",
    ] {
        assert!(
            !cluster_mod.contains(needle),
            "src/setup/cluster/mod.rs should stay focused on transport and dispatch instead of owning `{needle}`"
        );
    }

    assert!(
        repo_path_exists(root, "src/setup/cluster/tests.rs"),
        "setup cluster split test module should exist"
    );
}

#[test]
fn setup_cluster_kubernetes_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let kubernetes = read_repo_file(root, "src/setup/cluster/kubernetes.rs");

    for needle in [
        "fn resolve_kds_address(",
        "fn start_and_deploy(",
        "fn cluster_stop(",
        "fn dispatch_k8s_mode(",
        "fn cluster_k8s(",
    ] {
        assert!(
            !kubernetes.contains(needle),
            "src/setup/cluster/kubernetes.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/setup/cluster/kubernetes/address.rs",
        "src/setup/cluster/kubernetes/deploy.rs",
        "src/setup/cluster/kubernetes/modes.rs",
        "src/setup/cluster/kubernetes/remote.rs",
        "src/setup/cluster/kubernetes/runtime.rs",
    ] {
        assert!(
            repo_path_exists(root, path),
            "setup cluster kubernetes split module should exist: {path}"
        );
    }
}

#[test]
fn setup_universal_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let universal_mod = read_repo_file(root, "src/setup/cluster/universal.rs");

    for needle in [
        "fn universal_single_up(",
        "fn universal_global_zone_up(",
        "fn universal_global_two_zones_up(",
    ] {
        assert!(
            !universal_mod.contains(needle),
            "src/setup/cluster/universal.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/setup/cluster/universal/config.rs",
        "src/setup/cluster/universal/runtime.rs",
    ] {
        assert!(
            repo_path_exists(root, path),
            "setup universal split module should exist: {path}"
        );
    }
}

#[test]
fn setup_universal_runtime_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let runtime = read_repo_file(root, "src/setup/cluster/universal/runtime.rs");

    for needle in [
        "fn universal_single_up_compose(",
        "fn universal_global_zone_up(",
        "fn universal_global_two_zones_up(",
        "mod tests {",
    ] {
        assert!(
            !runtime.contains(needle),
            "src/setup/cluster/universal/runtime.rs should stay focused on runtime dispatch instead of owning `{needle}`"
        );
    }

    assert!(
        repo_path_exists(root, "src/setup/cluster/universal/runtime/compose.rs"),
        "setup universal runtime compose split module should exist"
    );
}
