/// Constants shared between suite-runner and suite-author.
pub mod shared {
    pub const GROUP_REQUIRED_SECTIONS: &[&str] = &["## Configure", "## Consume", "## Debug"];
}

/// Suite-runner constants and phase definitions.
pub mod suite_runner {
    pub const AGENT_PREFLIGHT: &str = "preflight-worker";
    pub const PREFLIGHT_REPLY_HEAD: &str = "suite-runner/preflight:";
    pub const PREFLIGHT_REPLY_PASS: &str = "pass";
    pub const PREFLIGHT_REPLY_FAIL: &str = "fail";

    pub const REPORT_LINE_LIMIT: usize = 220;
    pub const REPORT_CODE_BLOCK_LIMIT: usize = 4;

    pub const DENIED_LEGACY_SCRIPT_NAMES: &[&str] = &[
        "apply_tracked_manifest.py",
        "capture_state.py",
        "cluster_lifecycle.py",
        "install_gateway_api_crds.py",
        "preflight.py",
        "record_command.py",
        "validate_manifest.py",
    ];

    pub const DENIED_CLUSTER_BINARIES: &[&str] = &["kubectl", "kumactl", "helm", "docker", "k3d"];

    pub const DENIED_ADMIN_ENDPOINT_HINTS: &[&str] = &[
        "localhost:9901",
        "/config_dump",
        "/clusters",
        "/listeners",
        "/routes",
    ];

    pub const ALLOWED_RUN_FILES: &[&str] = &[
        "run-report.md",
        "run-status.json",
        "run-metadata.json",
        "current-deploy.json",
        "commands/command-log.md",
        "manifests/manifest-index.md",
    ];

    pub const DIRECT_WRITE_DENIED_RUN_FILES: &[&str] = &[
        "run-report.md",
        "run-status.json",
        "suite-runner-state.json",
        "commands/command-log.md",
    ];

    pub const ALLOWED_RUN_DIRS: &[&str] = &["artifacts", "commands", "manifests", "state"];

    pub const HARNESS_MANAGED_RUN_CONTROL_FILES: &[&str] = &[
        "run-report.md",
        "run-status.json",
        "suite-runner-state.json",
    ];

    pub const HARNESS_MANAGED_RUN_CONTROL_HINT: &str =
        "use `harness report group`, `harness runner-state`, or `harness closeout`";

    pub const COMMAND_LOG_HINT: &str =
        "use `harness record`, `harness run`, or recorded command artifacts instead";

    pub const DENIED_RUNNER_BINARIES: &[&str] = &["gh"];

    pub const DENIED_MAKE_TARGET_PREFIXES: &[&str] = &["k3d/", "kind/"];

    pub const MANIFEST_FIX_GATE_QUESTION: &str =
        "suite-runner/manifest-fix: how should this failure be handled?";
    pub const MANIFEST_FIX_TARGET_PREFIX: &str = "Suite target: ";
    pub const MANIFEST_FIX_GATE_OPTIONS: &[&str] = &[
        "Fix for this run only",
        "Fix in suite and this run",
        "Skip this step",
        "Stop run",
    ];
}

/// Suite-author constants and phase definitions.
pub mod suite_author {
    pub const GROUP_WRITE_PREFIX: &str = "groups/";
    pub const BASELINE_WRITE_PREFIX: &str = "baseline/";
    pub const ALLOWED_WRITE_FILES: &[&str] = &["suite.md"];

    pub const MODE_INTERACTIVE: &str = "interactive";
    pub const MODE_BYPASS: &str = "bypass";

    pub const INVENTORY_KIND: &str = "inventory";
    pub const COVERAGE_KIND: &str = "coverage";
    pub const VARIANTS_KIND: &str = "variants";
    pub const SCHEMA_KIND: &str = "schema";
    pub const PROPOSAL_KIND: &str = "proposal";
    pub const EDIT_REQUEST_KIND: &str = "edit-request";

    pub const RESULT_KINDS: &[&str] = &[
        INVENTORY_KIND,
        COVERAGE_KIND,
        VARIANTS_KIND,
        SCHEMA_KIND,
        PROPOSAL_KIND,
        EDIT_REQUEST_KIND,
    ];

    pub const WORKER_COVERAGE_READER: &str = "coverage-reader";
    pub const WORKER_VARIANT_ANALYZER: &str = "variant-analyzer";
    pub const WORKER_SCHEMA_VERIFIER: &str = "schema-verifier";
    pub const WORKER_SUITE_WRITER: &str = "suite-writer";
    pub const WORKER_BASELINE_WRITER: &str = "baseline-writer";
    pub const WORKER_GROUP_WRITER: &str = "group-writer";

    pub const PREWRITE_GATE_QUESTION: &str = "suite-author/prewrite: approve current proposal?";
    pub const POSTWRITE_GATE_QUESTION: &str = "suite-author/postwrite: approve saved suite?";
    pub const COPY_GATE_QUESTION: &str = "suite-author/copy: copy run command?";

    pub const PREWRITE_GATE_OPTIONS: &[&str] = &["Approve proposal", "Request changes", "Cancel"];
    pub const POSTWRITE_GATE_OPTIONS: &[&str] = &["Approve suite", "Request changes", "Cancel"];
    pub const COPY_GATE_OPTIONS: &[&str] = &["Copy command", "Skip"];
}

/// Compact/handoff constants.
pub mod compact {
    pub const HANDOFF_VERSION: u32 = 1;
    pub const HISTORY_LIMIT: usize = 10;
    pub const CHAR_LIMIT: usize = 3500;
    pub const SECTION_CHAR_LIMIT: usize = 1600;
    pub const SECTION_LINE_LIMIT: usize = 25;
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- Shared ---

    #[test]
    fn group_required_sections_has_three_entries() {
        assert_eq!(shared::GROUP_REQUIRED_SECTIONS.len(), 3);
        assert!(shared::GROUP_REQUIRED_SECTIONS.contains(&"## Configure"));
        assert!(shared::GROUP_REQUIRED_SECTIONS.contains(&"## Consume"));
        assert!(shared::GROUP_REQUIRED_SECTIONS.contains(&"## Debug"));
    }

    // --- SuiteRunner ---

    #[test]
    fn denied_cluster_binaries_has_expected_entries() {
        let bins = suite_runner::DENIED_CLUSTER_BINARIES;
        assert!(bins.contains(&"kubectl"));
        assert!(bins.contains(&"kumactl"));
        assert!(bins.contains(&"helm"));
        assert!(bins.contains(&"docker"));
        assert!(bins.contains(&"k3d"));
        assert_eq!(bins.len(), 5);
    }

    #[test]
    fn denied_legacy_script_names_has_expected_entries() {
        let scripts = suite_runner::DENIED_LEGACY_SCRIPT_NAMES;
        assert!(scripts.contains(&"preflight.py"));
        assert!(scripts.contains(&"capture_state.py"));
        assert!(scripts.contains(&"validate_manifest.py"));
        assert_eq!(scripts.len(), 7);
    }

    #[test]
    fn denied_admin_endpoint_hints_has_expected_entries() {
        let hints = suite_runner::DENIED_ADMIN_ENDPOINT_HINTS;
        assert!(hints.contains(&"localhost:9901"));
        assert!(hints.contains(&"/config_dump"));
        assert_eq!(hints.len(), 5);
    }

    #[test]
    fn allowed_run_files_has_expected_entries() {
        let files = suite_runner::ALLOWED_RUN_FILES;
        assert!(files.contains(&"run-report.md"));
        assert!(files.contains(&"run-status.json"));
        assert!(files.contains(&"commands/command-log.md"));
        assert_eq!(files.len(), 6);
    }

    #[test]
    fn direct_write_denied_run_files_has_expected_entries() {
        let files = suite_runner::DIRECT_WRITE_DENIED_RUN_FILES;
        assert!(files.contains(&"run-report.md"));
        assert!(files.contains(&"run-status.json"));
        assert!(files.contains(&"suite-runner-state.json"));
        assert!(files.contains(&"commands/command-log.md"));
        assert_eq!(files.len(), 4);
    }

    #[test]
    fn allowed_run_dirs_has_expected_entries() {
        let dirs = suite_runner::ALLOWED_RUN_DIRS;
        assert!(dirs.contains(&"artifacts"));
        assert!(dirs.contains(&"commands"));
        assert!(dirs.contains(&"manifests"));
        assert!(dirs.contains(&"state"));
        assert_eq!(dirs.len(), 4);
    }

    #[test]
    fn report_limits_are_positive() {
        const { assert!(suite_runner::REPORT_LINE_LIMIT > 0) }
        const { assert!(suite_runner::REPORT_CODE_BLOCK_LIMIT > 0) }
        assert_eq!(suite_runner::REPORT_LINE_LIMIT, 220);
        assert_eq!(suite_runner::REPORT_CODE_BLOCK_LIMIT, 4);
    }

    #[test]
    fn harness_managed_run_control_files() {
        let files = suite_runner::HARNESS_MANAGED_RUN_CONTROL_FILES;
        assert!(files.contains(&"run-report.md"));
        assert!(files.contains(&"run-status.json"));
        assert!(files.contains(&"suite-runner-state.json"));
        assert_eq!(files.len(), 3);
    }

    #[test]
    fn manifest_fix_gate_options_has_four_entries() {
        assert_eq!(suite_runner::MANIFEST_FIX_GATE_OPTIONS.len(), 4);
        assert!(suite_runner::MANIFEST_FIX_GATE_OPTIONS.contains(&"Fix for this run only"));
        assert!(suite_runner::MANIFEST_FIX_GATE_OPTIONS.contains(&"Stop run"));
    }

    #[test]
    fn denied_runner_binaries_has_gh() {
        assert!(suite_runner::DENIED_RUNNER_BINARIES.contains(&"gh"));
    }

    #[test]
    fn denied_make_target_prefixes() {
        let prefixes = suite_runner::DENIED_MAKE_TARGET_PREFIXES;
        assert!(prefixes.contains(&"k3d/"));
        assert!(prefixes.contains(&"kind/"));
    }

    // --- SuiteAuthor ---

    #[test]
    fn suite_author_write_prefixes() {
        assert_eq!(suite_author::GROUP_WRITE_PREFIX, "groups/");
        assert_eq!(suite_author::BASELINE_WRITE_PREFIX, "baseline/");
    }

    #[test]
    fn suite_author_allowed_write_files() {
        assert!(suite_author::ALLOWED_WRITE_FILES.contains(&"suite.md"));
        assert_eq!(suite_author::ALLOWED_WRITE_FILES.len(), 1);
    }

    #[test]
    fn suite_author_modes() {
        assert_eq!(suite_author::MODE_INTERACTIVE, "interactive");
        assert_eq!(suite_author::MODE_BYPASS, "bypass");
    }

    #[test]
    fn suite_author_result_kinds_count() {
        assert_eq!(suite_author::RESULT_KINDS.len(), 6);
        assert!(suite_author::RESULT_KINDS.contains(&"inventory"));
        assert!(suite_author::RESULT_KINDS.contains(&"coverage"));
        assert!(suite_author::RESULT_KINDS.contains(&"variants"));
        assert!(suite_author::RESULT_KINDS.contains(&"schema"));
        assert!(suite_author::RESULT_KINDS.contains(&"proposal"));
        assert!(suite_author::RESULT_KINDS.contains(&"edit-request"));
    }

    #[test]
    fn suite_author_gate_questions() {
        assert!(suite_author::PREWRITE_GATE_QUESTION.contains("prewrite"));
        assert!(suite_author::POSTWRITE_GATE_QUESTION.contains("postwrite"));
        assert!(suite_author::COPY_GATE_QUESTION.contains("copy"));
    }

    #[test]
    fn suite_author_gate_options() {
        assert_eq!(suite_author::PREWRITE_GATE_OPTIONS.len(), 3);
        assert_eq!(suite_author::POSTWRITE_GATE_OPTIONS.len(), 3);
        assert_eq!(suite_author::COPY_GATE_OPTIONS.len(), 2);
    }

    // --- Compact ---

    #[test]
    fn compact_constants() {
        assert_eq!(compact::HANDOFF_VERSION, 1);
        assert_eq!(compact::HISTORY_LIMIT, 10);
        assert_eq!(compact::CHAR_LIMIT, 3500);
        assert_eq!(compact::SECTION_CHAR_LIMIT, 1600);
        assert_eq!(compact::SECTION_LINE_LIMIT, 25);
    }
}
