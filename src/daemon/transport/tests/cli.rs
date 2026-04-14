use clap::Parser;

use super::super::{DaemonDevArgs, DaemonServeArgs, HARNESS_MONITOR_APP_GROUP_ID};

#[derive(Debug, Parser)]
struct DaemonServeArgsTestHarness {
    #[command(flatten)]
    args: DaemonServeArgs,
}

#[derive(Debug, Parser)]
struct DaemonDevArgsTestHarness {
    #[command(flatten)]
    args: DaemonDevArgs,
}

#[test]
fn daemon_dev_args_defaults_to_harness_monitor_app_group() {
    let parsed = DaemonDevArgsTestHarness::try_parse_from(["test"]).unwrap();
    assert_eq!(parsed.args.app_group_id, HARNESS_MONITOR_APP_GROUP_ID);
    assert_eq!(parsed.args.host, "127.0.0.1");
    assert_eq!(parsed.args.port, 0);
    assert!(parsed.args.codex_ws_url.is_none());
}

#[test]
fn daemon_dev_args_accepts_overrides() {
    let parsed = DaemonDevArgsTestHarness::try_parse_from([
        "test",
        "--host",
        "0.0.0.0",
        "--port",
        "9999",
        "--app-group-id",
        "com.example.group",
        "--codex-ws-url",
        "ws://127.0.0.1:7777",
    ])
    .unwrap();
    assert_eq!(parsed.args.host, "0.0.0.0");
    assert_eq!(parsed.args.port, 9999);
    assert_eq!(parsed.args.app_group_id, "com.example.group");
    assert_eq!(
        parsed.args.codex_ws_url.as_deref(),
        Some("ws://127.0.0.1:7777")
    );
}

#[test]
fn daemon_dev_rejects_when_sandboxed_env_truthy() {
    temp_env::with_var("HARNESS_SANDBOXED", Some("1"), || {
        let error = DaemonDevArgs::ensure_not_sandboxed()
            .expect_err("dev mode must refuse to run under sandbox env");
        let message = error.to_string();
        assert!(
            message.contains("HARNESS_SANDBOXED"),
            "error should mention the offending env var, got: {message}"
        );
    });
}

#[test]
fn daemon_dev_allows_when_sandboxed_env_unset() {
    temp_env::with_var("HARNESS_SANDBOXED", Option::<&str>::None, || {
        DaemonDevArgs::ensure_not_sandboxed().expect("dev mode should run when unsandboxed");
    });
}

#[test]
fn daemon_dev_spawn_plan_forwards_host_and_port_to_serve() {
    let dev = DaemonDevArgs {
        host: "127.0.0.1".to_string(),
        port: 8123,
        app_group_id: HARNESS_MONITOR_APP_GROUP_ID.to_string(),
        codex_ws_url: None,
    };
    temp_env::with_var("HARNESS_APP_GROUP_ID", Some("com.user.preset"), || {
        let plan = dev.spawn_plan();
        assert_eq!(
            plan.args,
            vec![
                "daemon".to_string(),
                "serve".to_string(),
                "--host".to_string(),
                "127.0.0.1".to_string(),
                "--port".to_string(),
                "8123".to_string(),
            ]
        );
    });
}

#[test]
fn daemon_dev_spawn_plan_includes_codex_ws_url() {
    let dev = DaemonDevArgs {
        host: "127.0.0.1".to_string(),
        port: 0,
        app_group_id: HARNESS_MONITOR_APP_GROUP_ID.to_string(),
        codex_ws_url: Some("ws://127.0.0.1:7777".to_string()),
    };
    temp_env::with_var("HARNESS_APP_GROUP_ID", Some("com.user.preset"), || {
        let plan = dev.spawn_plan();
        assert!(plan.args.contains(&"--codex-ws-url".to_string()));
        assert!(plan.args.contains(&"ws://127.0.0.1:7777".to_string()));
    });
}

#[test]
fn daemon_dev_spawn_plan_skips_blank_codex_ws_url() {
    let dev = DaemonDevArgs {
        host: "127.0.0.1".to_string(),
        port: 0,
        app_group_id: HARNESS_MONITOR_APP_GROUP_ID.to_string(),
        codex_ws_url: Some("   ".to_string()),
    };
    temp_env::with_var("HARNESS_APP_GROUP_ID", Some("com.user.preset"), || {
        let plan = dev.spawn_plan();
        assert!(!plan.args.contains(&"--codex-ws-url".to_string()));
    });
}

#[test]
fn daemon_dev_spawn_plan_defaults_app_group_when_env_unset() {
    temp_env::with_var("HARNESS_APP_GROUP_ID", Option::<&str>::None, || {
        let dev = DaemonDevArgs {
            host: "127.0.0.1".to_string(),
            port: 0,
            app_group_id: "com.example.custom".to_string(),
            codex_ws_url: None,
        };
        let plan = dev.spawn_plan();
        assert_eq!(
            plan.set_env,
            vec![(
                "HARNESS_APP_GROUP_ID".to_string(),
                "com.example.custom".to_string(),
            )]
        );
        assert_eq!(
            plan.log_effective_app_group.as_deref(),
            Some("com.example.custom")
        );
    });
}

#[test]
fn daemon_dev_spawn_plan_defaults_app_group_when_env_blank() {
    temp_env::with_var("HARNESS_APP_GROUP_ID", Some("   "), || {
        let dev = DaemonDevArgs {
            host: "127.0.0.1".to_string(),
            port: 0,
            app_group_id: "com.example.custom".to_string(),
            codex_ws_url: None,
        };
        let plan = dev.spawn_plan();
        assert_eq!(
            plan.set_env,
            vec![(
                "HARNESS_APP_GROUP_ID".to_string(),
                "com.example.custom".to_string(),
            )]
        );
        assert_eq!(
            plan.log_effective_app_group.as_deref(),
            Some("com.example.custom")
        );
    });
}

#[test]
fn daemon_dev_spawn_plan_preserves_existing_app_group_env() {
    temp_env::with_var("HARNESS_APP_GROUP_ID", Some("com.user.preset"), || {
        let dev = DaemonDevArgs {
            host: "127.0.0.1".to_string(),
            port: 0,
            app_group_id: "com.example.custom".to_string(),
            codex_ws_url: None,
        };
        let plan = dev.spawn_plan();
        assert!(plan.set_env.is_empty());
        assert!(plan.log_effective_app_group.is_none());
    });
}

#[test]
fn daemon_dev_spawn_plan_always_clears_sandbox_env_for_child() {
    let dev = DaemonDevArgs {
        host: "127.0.0.1".to_string(),
        port: 0,
        app_group_id: HARNESS_MONITOR_APP_GROUP_ID.to_string(),
        codex_ws_url: None,
    };
    temp_env::with_var("HARNESS_APP_GROUP_ID", Some("com.user.preset"), || {
        let plan = dev.spawn_plan();
        assert_eq!(plan.unset_env, vec!["HARNESS_SANDBOXED".to_string()]);
    });
}

#[test]
fn daemon_serve_args_default_is_unsandboxed() {
    let parsed = DaemonServeArgsTestHarness::try_parse_from(["test"]).unwrap();
    assert!(!parsed.args.sandboxed);
}

#[test]
fn daemon_serve_args_accepts_sandboxed_flag() {
    let parsed = DaemonServeArgsTestHarness::try_parse_from(["test", "--sandboxed"]).unwrap();
    assert!(parsed.args.sandboxed);
}

#[test]
fn daemon_serve_args_enables_sandbox_via_env() {
    temp_env::with_var("HARNESS_SANDBOXED", Some("1"), || {
        let parsed = DaemonServeArgsTestHarness::try_parse_from(["test"]).unwrap();
        let effective = parsed.args.sandboxed || super::super::super::service::sandboxed_from_env();
        assert!(effective);
    });
}

#[test]
fn daemon_serve_args_ignores_env_when_unset() {
    temp_env::with_var("HARNESS_SANDBOXED", Option::<&str>::None, || {
        let parsed = DaemonServeArgsTestHarness::try_parse_from(["test"]).unwrap();
        let effective = parsed.args.sandboxed || super::super::super::service::sandboxed_from_env();
        assert!(!effective);
    });
}
