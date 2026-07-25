// Coverage for `harness setup gateway`, lifted out of the retired record
// command tests so removing those did not take this adapter's only test with
// them.

use std::env;
use std::fs;

use harness::setup::GatewayArgs;
use harness_testkit::FakeToolchain;

use super::super::helpers::*;

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn bootstrap_command_runs_gateway_api_crd_install() {
    let tmp = tempfile::tempdir().unwrap();
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();
    fs::write(
        repo_root.join("go.mod"),
        "module example.com/repo\n\nrequire sigs.k8s.io/gateway-api v1.2.0\n",
    )
    .unwrap();

    let mut tc = FakeToolchain::new();
    tc.add_kubectl("customresourcedefinition.apiextensions.k8s.io/gatewayclasses found");
    tc.add_curl();

    let orig_path = env::var("PATH").unwrap_or_default();
    let new_path = tc.path_with_prepend(&orig_path);

    temp_env::with_vars([("PATH", Some(&new_path))], || {
        let result = gateway_cmd(GatewayArgs {
            kubeconfig: None,
            repo_root: Some(repo_root.to_string_lossy().to_string()),
            check_only: true,
            uninstall: false,
        })
        .execute();
        assert!(result.is_ok(), "gateway check should succeed: {result:?}");
    });
}
