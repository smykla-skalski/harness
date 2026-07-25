// Coverage for `harness setup gateway`. This test lived among the retired
// record command tests, which were its only home, so it moved here rather
// than disappearing when that directory went. It was called
// `bootstrap_command_runs_gateway_api_crd_install` there, a name that named
// neither the command it drives nor the check-only path it takes.

use std::env;
use std::fs;
use std::sync::PoisonError;

use harness::setup::GatewayArgs;
use harness_testkit::FakeToolchain;

use super::super::helpers::*;

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn setup_gateway_check_finds_gateway_api_crds() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
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
