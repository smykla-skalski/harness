use super::*;

#[test]
fn kuma_block_roots_stay_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

    for (path, needles, split_path) in [
        (
            "src/infra/blocks/kuma/mod.rs",
            &[
                "fn api_path_preserves_leading_slash()",
                "fn derives_universal_image_from_cp_image()",
                "mod tests {",
            ][..],
            "src/infra/blocks/kuma/tests.rs",
        ),
        (
            "src/infra/blocks/kuma/defaults.rs",
            &[
                "fn default_cp_addr_uses_api_port()",
                "fn derive_universal_service_image_rewrites_cp_name()",
                "mod tests {",
            ][..],
            "src/infra/blocks/kuma/defaults/tests.rs",
        ),
        (
            "src/infra/blocks/kuma/manifest.rs",
            &[
                "fn mesh_resource_uses_top_level_path()",
                "fn mesh_scoped_resource_defaults_mesh()",
                "mod tests {",
            ][..],
            "src/infra/blocks/kuma/manifest/tests.rs",
        ),
        (
            "src/infra/blocks/kuma/fake.rs",
            &[
                "fn fake_returns_expected_defaults()",
                "fn fake_satisfies_modes_non_empty()",
                "mod tests {",
            ][..],
            "src/infra/blocks/kuma/fake/tests.rs",
        ),
        (
            "src/infra/blocks/kuma/compose.rs",
            &[
                "fn single_zone_recipe_builds_topology()",
                "fn postgres_recipe_adds_postgres_service()",
                "mod tests {",
            ][..],
            "src/infra/blocks/kuma/compose/tests.rs",
        ),
        (
            "src/infra/blocks/kuma/service.rs",
            &[
                "fn files_for_uses_standard_temp_paths()",
                "fn render_dataplane_uses_standard_template_without_transparent_proxy()",
                "mod tests {",
            ][..],
            "src/infra/blocks/kuma/service/tests.rs",
        ),
        (
            "src/infra/blocks/kuma/token.rs",
            &[
                "fn token_kind_maps_to_api_values()",
                "fn parse_token_response_rejects_empty_body()",
                "mod tests {",
            ][..],
            "src/infra/blocks/kuma/token/tests.rs",
        ),
    ] {
        let contents = fs::read_to_string(root.join(path)).unwrap();
        for needle in needles {
            assert!(
                !contents.contains(needle),
                "{path} should stay focused on production Kuma block logic instead of owning `{needle}`"
            );
        }
        assert!(
            root.join(split_path).exists(),
            "kuma block split test module should exist: {split_path}"
        );
    }
}

#[test]
fn helm_block_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let helm = fs::read_to_string(root.join("src/infra/blocks/helm.rs")).unwrap();

    for needle in [
        "pub struct HelmSetting {",
        "pub struct HelmDeployer {",
        "pub struct FakePackageDeployer {",
        "fn helm_setting_parses_cli_arg(",
        "fn fake_package_deployer_tracks_release_state(",
        "mod tests {",
    ] {
        assert!(
            !helm.contains(needle),
            "src/infra/blocks/helm.rs should stay focused on production Helm deployment behavior instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/infra/blocks/helm/tests.rs").exists(),
        "helm block split test module should exist"
    );
    for path in [
        "src/infra/blocks/helm/contract.rs",
        "src/infra/blocks/helm/runtime.rs",
        "src/infra/blocks/helm/fake.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "helm block split module should exist: {path}"
        );
    }
}
