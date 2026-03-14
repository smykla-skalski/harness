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
    pub const STATUS_PENDING: &str = "pending";
    pub const STATUS_CONSUMED: &str = "consumed";
    pub const HISTORY_LIMIT: usize = 10;
    pub const CHAR_LIMIT: usize = 3500;
    pub const SECTION_CHAR_LIMIT: usize = 1600;
    pub const SECTION_LINE_LIMIT: usize = 25;
}

#[cfg(test)]
mod tests {}
