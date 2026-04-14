use std::fs;
use std::path::PathBuf;

use harness::hooks::hook_result::HookResult;
use tempfile::tempdir;

use super::schema::{ENV_CRD_DIR, ENV_OPENAPI_PATH};
use super::{
    HookPayloadBuilder, PolicyGroupBuilder, RunDirBuilder, assert_allow, assert_deny, assert_warn,
    default_group, default_suite, default_universal_run, make_bash_payload,
    make_hook_context_with_run, make_multi_write_payload, make_question_answer_payload,
    make_stop_payload, read_run_status, read_runner_state, seed_cluster_state,
    seed_kubectl_validate_state, write_group, write_meshmetric_group, write_run_status,
    write_suite,
};

#[test]
fn builders_round_trip_smoke_covers_public_surface() {
    let tempdir = tempdir().expect("create builders tempdir");
    let fixtures_dir = tempdir.path().join("fixtures");
    let suite_path = fixtures_dir.join("suite.md");
    let group_path = fixtures_dir.join("groups").join("g01.md");
    let meshmetric_path = fixtures_dir.join("groups").join("g02.md");

    write_suite(&suite_path);
    write_group(&group_path);
    write_meshmetric_group(&meshmetric_path, true);

    assert!(suite_path.exists());
    assert!(group_path.exists());
    assert!(
        fs::read_to_string(&meshmetric_path)
            .expect("read meshmetric group")
            .contains("kind: MeshService")
    );
    assert!(
        default_suite()
            .feature("builder-smoke")
            .build_markdown()
            .contains("suite_id: example.suite")
    );
    assert!(
        default_group()
            .story("builder smoke story")
            .build_markdown()
            .contains("group_id: g01")
    );

    let resources_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("resources")
        .join("kuma");
    let openapi_path = resources_dir.join("openapi.yaml");
    let crd_dir = resources_dir.join("crds");
    temp_env::with_vars(
        [
            (ENV_OPENAPI_PATH, Some(openapi_path.as_path())),
            (ENV_CRD_DIR, Some(crd_dir.as_path())),
        ],
        || {
            let universal_policy = PolicyGroupBuilder::new("g-policy", "MeshTimeout")
                .story("policy story")
                .universal()
                .build_markdown();
            assert!(universal_policy.contains("type: MeshTimeout"));

            let kubernetes_policy = PolicyGroupBuilder::new("g-policy-k8s", "MeshTimeout")
                .story("policy story")
                .kubernetes()
                .namespace("kuma-system")
                .build_markdown();
            assert!(kubernetes_policy.contains("kind: MeshTimeout"));
            assert!(kubernetes_policy.contains("namespace: kuma-system"));
        },
    );

    let run_root = tempdir.path().join("run-root");
    let (run_dir, suite_dir) = RunDirBuilder::new(&run_root, "run-smoke")
        .suite(default_suite())
        .group(default_group())
        .build();
    assert!(run_dir.exists());
    assert!(suite_dir.join("suite.md").exists());

    let status = read_run_status(&run_dir);
    assert_eq!(status.run_id, "run-smoke");
    write_run_status(&run_dir, &status);
    assert!(read_runner_state(&run_dir).is_some());

    seed_cluster_state(&run_dir, "/tmp/kubeconfig");
    assert!(run_dir.join("state").join("cluster.json").exists());

    let xdg_data_home = tempdir.path().join("xdg");
    let binary_path = PathBuf::from("/tmp/kubectl-validate");
    seed_kubectl_validate_state(&xdg_data_home, "allow", Some(&binary_path));
    assert!(
        xdg_data_home
            .join("harness")
            .join("tooling")
            .join("kubectl-validate.json")
            .exists()
    );

    let bash_payload = make_bash_payload("echo hi");
    assert_eq!(bash_payload.tool_name, "Bash");
    let multi_write_payload = make_multi_write_payload(&["a.md", "b.md"]);
    assert_eq!(multi_write_payload.tool_name, "Write");
    let question_payload = make_question_answer_payload("Proceed?", &["Yes", "No"], "Yes");
    assert_eq!(question_payload.tool_name, "AskUserQuestion");
    let stop_payload = make_stop_payload();
    assert!(stop_payload.stop_hook_active);

    let direct_context = HookPayloadBuilder::new()
        .command("echo hi")
        .build_context("suite:new");
    assert!(direct_context.tool.is_some());

    let run_context = HookPayloadBuilder::new()
        .command("echo hi")
        .build_context_with_run("suite:new", &run_dir);
    assert_eq!(run_context.run_dir.as_deref(), Some(run_dir.as_path()));
    assert!(run_context.run.is_some());

    let helper_context =
        make_hook_context_with_run("suite:new", make_bash_payload("echo hi"), &run_dir);
    assert_eq!(helper_context.run_dir.as_deref(), Some(run_dir.as_path()));
    assert!(helper_context.skill_active);

    assert_allow(&HookResult::allow());
    assert_deny(&HookResult::deny("DENY", "blocked"));
    assert_warn(&HookResult::warn("WARN", "caution"));

    let universal_root = tempdir.path().join("universal-root");
    let universal_run_dir = default_universal_run(&universal_root, "run-universal").build_run_dir();
    assert_eq!(
        read_run_status(&universal_run_dir).profile,
        "single-zone-universal"
    );
}
