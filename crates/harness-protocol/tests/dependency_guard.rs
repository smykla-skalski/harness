#[test]
fn protocol_package_has_no_harness_runtime_dependency() {
    let manifest = include_str!("../Cargo.toml");
    assert!(!manifest.lines().any(|line| {
        let line = line.trim_start();
        line.starts_with("harness =") || line.starts_with("harness-") && line.contains("path =")
    }));
    assert!(
        !manifest.contains("agent-client-protocol"),
        "wire models must not compile the ACP runtime implementation"
    );
}

#[test]
fn canonical_model_sources_do_not_import_application_layers() {
    let sources = [
        include_str!("../src/agent_models.rs"),
        include_str!("../src/managed_agents/acp/models.rs"),
        include_str!("../src/managed_agents/acp/permission_wire.rs"),
        include_str!("../src/managed_agents/acp/request_wire.rs"),
        include_str!("../src/managed_agents/acp/snapshot_wire.rs"),
        include_str!("../src/managed_agents/acp/wire.rs"),
        include_str!("../src/managed_agents/runtime_models.rs"),
        include_str!("../src/managed_agents/tui.rs"),
        include_str!("../../../src/agents/kind/mod.rs"),
        include_str!("../../../src/agents/kind/disconnect.rs"),
        include_str!("../../../src/agents/runtime/event.rs"),
        include_str!("../../../src/session/types/mod.rs"),
        include_str!("../../../src/session/types/agents.rs"),
        include_str!("../../../src/session/types/events.rs"),
        include_str!("../../../src/session/types/identity.rs"),
        include_str!("../../../src/session/types/policy.rs"),
        include_str!("../../../src/session/types/state.rs"),
        include_str!("../../../src/session/types/tasks.rs"),
    ];
    for source in sources {
        for forbidden in [
            "crate::app",
            "crate::daemon",
            "crate::hooks::runtime",
            "crate::session::service",
            "crate::session::storage",
            "crate::workflow",
        ] {
            assert!(
                !source.contains(forbidden),
                "canonical model imports forbidden application layer {forbidden}"
            );
        }
    }
}
