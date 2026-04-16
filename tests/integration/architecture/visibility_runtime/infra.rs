use super::*;
use super::super::helpers::{read_repo_file, repo_path_exists};

#[test]
fn infra_environment_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let environment = read_repo_file(root, "src/infra/environment.rs");

    for needle in ["merge_env_prepends_build_artifacts_to_path", "mod tests {"] {
        assert!(
            !environment.contains(needle),
            "src/infra/environment.rs should stay focused on production environment helpers instead of owning `{needle}`"
        );
    }

    assert!(
        repo_path_exists(root, "src/infra/environment/tests.rs"),
        "infra environment split test module should exist"
    );
}

#[test]
fn docker_block_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let docker_mod = read_repo_file(root, "src/infra/blocks/docker/mod.rs");

    for needle in [
        "impl ContainerRuntime for DockerContainerRuntime",
        "struct FakeContainer {",
        "pub struct FakeContainerRuntime {",
        "mod tests {",
    ] {
        assert!(
            !docker_mod.contains(needle),
            "src/infra/blocks/docker/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/infra/blocks/docker/runtime_cli.rs",
        "src/infra/blocks/docker/runtime_bollard.rs",
        "src/infra/blocks/docker/fake.rs",
        "src/infra/blocks/docker/tests.rs",
    ] {
        assert!(
            repo_path_exists(root, path),
            "docker block split module should exist: {path}"
        );
    }
}

#[test]
fn compose_block_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let compose_mod = read_repo_file(root, "src/infra/blocks/compose/mod.rs");

    for needle in [
        "pub struct DockerComposeOrchestrator",
        "pub struct FakeComposeOrchestrator",
        "mod tests {",
    ] {
        assert!(
            !compose_mod.contains(needle),
            "src/infra/blocks/compose/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/infra/blocks/compose/runtime_cli.rs",
        "src/infra/blocks/compose/runtime_bollard.rs",
        "src/infra/blocks/compose/fake.rs",
        "src/infra/blocks/compose/tests.rs",
    ] {
        assert!(
            repo_path_exists(root, path),
            "compose block split module should exist: {path}"
        );
    }
}

#[test]
fn build_block_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let build_mod = read_repo_file(root, "src/infra/blocks/build.rs");

    for needle in [
        "pub struct BuildTarget {",
        "pub struct ProcessBuildSystem {",
        "pub struct FakeBuildSystem {",
        "mod tests {",
    ] {
        assert!(
            !build_mod.contains(needle),
            "src/infra/blocks/build.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/infra/blocks/build/contract.rs",
        "src/infra/blocks/build/runtime.rs",
        "src/infra/blocks/build/fake.rs",
        "src/infra/blocks/build/tests.rs",
    ] {
        assert!(
            repo_path_exists(root, path),
            "build block split module should exist: {path}"
        );
    }
}

#[test]
fn infra_small_roots_stay_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

    for (path, needles, split_path) in [
        (
            "src/infra/blocks/clock.rs",
            &[
                "fn system_clock_produces_valid_iso8601()",
                "fn clock_is_send_sync()",
                "mod tests {",
            ][..],
            "src/infra/blocks/clock/tests.rs",
        ),
        (
            "src/infra/blocks/error.rs",
            &[
                "fn block_error_new_preserves_fields()",
                "fn block_error_is_send_sync()",
                "mod tests {",
            ][..],
            "src/infra/blocks/error/tests.rs",
        ),
        (
            "src/infra/blocks/registry.rs",
            &[
                "fn denied_binaries_cover_managed_cluster_tools()",
                "fn parse_rejects_unknown_requirement()",
                "mod tests {",
            ][..],
            "src/infra/blocks/registry/tests.rs",
        ),
        (
            "src/infra/blocks/envoy.rs",
            &[
                "fn fake_proxy_returns_canned_dump()",
                "fn proxy_introspector_is_send_sync()",
                "mod tests {",
            ][..],
            "src/infra/blocks/envoy/tests.rs",
        ),
    ] {
        let contents = read_repo_file(root, path);
        for needle in needles {
            assert!(
                !contents.contains(needle),
                "{path} should stay focused on production block logic instead of owning `{needle}`"
            );
        }
        assert!(
            repo_path_exists(root, split_path),
            "infra split test module should exist: {split_path}"
        );
    }
}

#[test]
fn versioned_json_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let versioned_json = read_repo_file(root, "src/infra/persistence/versioned_json.rs");

    for needle in [
        "fn load_returns_none_when_file_missing(",
        "fn update_serializes_concurrent_writers(",
        "mod tests {",
    ] {
        assert!(
            !versioned_json.contains(needle),
            "src/infra/persistence/versioned_json.rs should stay focused on production persistence logic instead of owning `{needle}`"
        );
    }

    assert!(
        repo_path_exists(root, "src/infra/persistence/versioned_json/tests.rs"),
        "versioned json split test module should exist"
    );
}

#[test]
fn infra_io_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let infra_io = read_repo_file(root, "src/infra/io/mod.rs");

    for needle in [
        "fn write_and_read_json(",
        "fn append_markdown_row_appends_to_existing(",
        "mod tests {",
    ] {
        assert!(
            !infra_io.contains(needle),
            "src/infra/io/mod.rs should stay focused on production io helpers instead of owning `{needle}`"
        );
    }

    assert!(
        repo_path_exists(root, "src/infra/io/tests.rs"),
        "infra io split test module should exist"
    );
}

#[test]
fn kubernetes_block_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let kubernetes_mod = read_repo_file(root, "src/infra/blocks/kubernetes.rs");

    for needle in [
        "serde_json::from_str(&result.stdout)",
        "containerStatuses",
        "pub struct FakeKubernetesOperator {",
        "pub struct FakeLocalClusterManager {",
        "mod tests {",
    ] {
        assert!(
            !kubernetes_mod.contains(needle),
            "src/infra/blocks/kubernetes.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/infra/blocks/kubernetes/fake.rs",
        "src/infra/blocks/kubernetes/pods.rs",
        "src/infra/blocks/kubernetes/tests.rs",
    ] {
        assert!(
            repo_path_exists(root, path),
            "kubernetes block split module should exist: {path}"
        );
    }
}

#[test]
fn http_block_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let http_mod = read_repo_file(root, "src/infra/blocks/http.rs");

    for needle in [
        "impl HttpClient for ReqwestHttpClient",
        "pub struct FakeHttpClient {",
        "fn reqwest_http_client_get_returns_body()",
        "mod tests {",
    ] {
        assert!(
            !http_mod.contains(needle),
            "src/infra/blocks/http.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/infra/blocks/http/client.rs",
        "src/infra/blocks/http/fake.rs",
        "src/infra/blocks/http/tests.rs",
        "src/infra/blocks/http/types.rs",
    ] {
        assert!(
            repo_path_exists(root, path),
            "http block split module should exist: {path}"
        );
    }
}
