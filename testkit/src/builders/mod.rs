// Builder types for constructing test fixture markdown and JSON payloads.
// Each builder produces the exact format expected by the harness parsers,
// replacing inline YAML/JSON strings scattered across test files.
//
// Test utilities intentionally panic on setup failures - callers are #[test]
// functions where an expect() failure is the correct way to surface problems.

mod frontmatter;
mod group;
mod hook;
mod policy;
mod run;
mod schema;
mod suite;

#[cfg(test)]
mod tests;

pub use group::{
    GroupBuilder, MeshMetricGroupBuilder, default_group, write_group, write_meshmetric_group,
};
pub use hook::{
    HookPayloadBuilder, assert_allow, assert_decision, assert_deny, assert_warn, make_bash_payload,
    make_empty_payload, make_hook_context, make_hook_context_with_run, make_multi_write_payload,
    make_question_answer_payload, make_question_payload, make_stop_payload, make_write_payload,
};
pub use policy::{PolicyGroupBuilder, PolicySchemaTarget};
pub use run::{
    RunDirBuilder, default_kubernetes_run, default_universal_run, init_run, init_run_with_suite,
    init_universal_run, init_universal_run_with_suite, read_run_status, read_runner_state,
    seed_cluster_state, seed_kubectl_validate_state, write_run_status,
};
pub use suite::{SuiteBuilder, default_suite, default_universal_suite, write_suite};
