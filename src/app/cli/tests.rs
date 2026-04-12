use super::*;
use crate::agents::transport::AgentPromptSubmitArgs;
use crate::daemon::bridge::BridgeCapability;
use crate::daemon::transport::{DaemonCommand, HARNESS_MONITOR_APP_GROUP_ID};
use crate::hooks::adapters::HookAgent;
use crate::observe::{ObserveArgs, ObserveMode};
use crate::run::{
    ApiArgs, ApiMethod, DoctorArgs, EnvoyCommand, FinishArgs, KumaCommand, KumactlArgs,
    KumactlCommand, RepairArgs, ReportCommand, ResumeArgs, StartArgs,
};
use crate::session::transport::SessionObserveArgs;
use crate::setup::{CapabilitiesArgs, ClusterArgs, GatewayArgs, KumaSetupCommand};
use clap::{CommandFactory, error::ErrorKind};
use std::path::Path;

fn expect_cluster_args(command: Command) -> ClusterArgs {
    match command {
        Command::Setup {
            command: SetupCommand::Kuma(args),
        } => match args.command {
            KumaSetupCommand::Cluster(args) => args,
        },
        _ => panic!("expected Cluster command"),
    }
}

fn assert_remote_cluster_args(args: &ClusterArgs) {
    assert_remote_cluster_core(args);
    assert_remote_cluster_targets(args);
}

fn assert_remote_cluster_core(args: &ClusterArgs) {
    assert_eq!(args.provider.as_deref(), Some("remote"));
    assert_eq!(args.push_prefix.as_deref(), Some("ghcr.io/acme/kuma"));
    assert_eq!(args.push_tag.as_deref(), Some("pr-123"));
    assert_eq!(args.mode, "global-zone-up");
    assert_eq!(args.cluster_name, "kuma-1");
    assert_eq!(args.extra_cluster_names, vec!["kuma-2", "zone-1"]);
}

fn assert_remote_cluster_targets(args: &ClusterArgs) {
    assert_eq!(args.remote.len(), 2);
    assert_first_remote_cluster_target(args);
    assert_second_remote_cluster_target(args);
}

fn assert_first_remote_cluster_target(args: &ClusterArgs) {
    assert_eq!(args.remote[0].name, "kuma-1");
    assert_eq!(args.remote[0].kubeconfig, "/tmp/global.yaml");
    assert_eq!(args.remote[0].context.as_deref(), Some("global"));
}

fn assert_second_remote_cluster_target(args: &ClusterArgs) {
    assert_eq!(args.remote[1].name, "kuma-2");
    assert_eq!(args.remote[1].kubeconfig, "/tmp/zone.yaml");
    assert!(args.remote[1].context.is_none());
}

#[test]
fn all_expected_subcommands_registered() {
    let cmd = Cli::command();
    let names: Vec<&str> = cmd.get_subcommands().map(clap::Command::get_name).collect();
    for expected in [
        "create",
        "hook",
        "observe",
        "pre-compact",
        "run",
        "session-start",
        "session-stop",
        "setup",
    ] {
        assert!(names.contains(&expected), "missing subcommand: {expected}");
    }
}

#[test]
fn hook_subcommand_lists_all_hooks() {
    let cmd = Cli::command();
    let hook_cmd = cmd
        .get_subcommands()
        .find(|s| s.get_name() == "hook")
        .expect("hook subcommand missing");
    let hook_names: Vec<&str> = hook_cmd
        .get_subcommands()
        .map(clap::Command::get_name)
        .collect();
    for expected in [
        "tool-guard",
        "guard-stop",
        "tool-result",
        "tool-failure",
        "context-agent",
        "validate-agent",
    ] {
        assert!(hook_names.contains(&expected), "missing hook: {expected}");
    }
}

#[test]
fn parse_hook_command() {
    let cli = Cli::try_parse_from(["harness", "hook", "suite:run", "tool-guard"]).unwrap();
    match cli.command {
        Command::Hook(HookArgs { skill, hook, .. }) => {
            assert_eq!(skill, "suite:run");
            assert_eq!(hook.name(), "tool-guard");
        }
        _ => panic!("expected Hook command"),
    }
}

#[test]
fn parse_bootstrap_defaults_to_all_agents() {
    let cli = Cli::try_parse_from(["harness", "setup", "bootstrap"]).unwrap();
    let Command::Setup {
        command: SetupCommand::Bootstrap(args),
    } = cli.command
    else {
        panic!("expected bootstrap command");
    };
    assert!(args.agents.is_empty());
}

#[test]
fn parse_bootstrap_agents_csv() {
    let cli =
        Cli::try_parse_from(["harness", "setup", "bootstrap", "--agents", "claude,codex"]).unwrap();
    let Command::Setup {
        command: SetupCommand::Bootstrap(args),
    } = cli.command
    else {
        panic!("expected bootstrap command");
    };
    assert_eq!(args.agents, vec![HookAgent::Claude, HookAgent::Codex]);
}

#[test]
fn parse_init_command() {
    let cli = Cli::try_parse_from([
        "harness",
        "run",
        "init",
        "--suite",
        "suite.md",
        "--run-id",
        "r01",
        "--profile",
        "single-zone",
    ])
    .unwrap();
    let Command::Run { command } = cli.command else {
        panic!("expected Run command");
    };
    let RunCommand::Init(InitArgs {
        suite,
        run_id,
        profile,
        repo_root,
        run_root,
    }) = *command
    else {
        panic!("expected Init command");
    };
    assert_eq!(suite, "suite.md");
    assert_eq!(run_id, "r01");
    assert_eq!(profile, "single-zone");
    assert!(repo_root.is_none());
    assert!(run_root.is_none());
}

#[test]
fn parse_start_command() {
    let cli = Cli::try_parse_from([
        "harness",
        "run",
        "start",
        "--suite",
        "suite.md",
        "--profile",
        "single-zone",
        "--repo-root",
        "/repo",
    ])
    .unwrap();
    let Command::Run { command } = cli.command else {
        panic!("expected Run command");
    };
    let RunCommand::Start(StartArgs {
        suite,
        run_id,
        profile,
        repo_root,
        run_root,
    }) = *command
    else {
        panic!("expected Start command");
    };
    assert_eq!(suite, "suite.md");
    assert!(run_id.is_none());
    assert_eq!(profile, "single-zone");
    assert_eq!(repo_root.as_deref(), Some("/repo"));
    assert!(run_root.is_none());
}

#[test]
fn parse_record_with_trailing_command() {
    let cli = Cli::try_parse_from([
        "harness",
        "run",
        "record",
        "--label",
        "test",
        "--",
        "kubectl",
        "get",
        "pods",
        "-n",
        "kuma-system",
    ])
    .unwrap();
    let Command::Run { command } = cli.command else {
        panic!("expected Run command");
    };
    let RunCommand::Record(RecordArgs { label, command, .. }) = *command else {
        panic!("expected Record command");
    };
    assert_eq!(label.as_deref(), Some("test"));
    assert_eq!(command, vec!["kubectl", "get", "pods", "-n", "kuma-system"]);
}

#[test]
fn parse_finish_command() {
    let cli = Cli::try_parse_from(["harness", "run", "finish", "--run-dir", "/tmp/run"]).unwrap();
    let Command::Run { command } = cli.command else {
        panic!("expected Run command");
    };
    let RunCommand::Finish(FinishArgs { run_dir }) = *command else {
        panic!("expected Finish command");
    };
    assert_eq!(run_dir.run_dir.as_deref(), Some(Path::new("/tmp/run")));
    assert!(run_dir.run_id.is_none());
    assert!(run_dir.run_root.is_none());
}

#[test]
fn parse_resume_command() {
    let cli = Cli::try_parse_from([
        "harness",
        "run",
        "resume",
        "--message",
        "Recovered from stop",
        "--run-id",
        "r01",
        "--run-root",
        "/tmp/runs",
    ])
    .unwrap();
    let Command::Run { command } = cli.command else {
        panic!("expected Run command");
    };
    let RunCommand::Resume(ResumeArgs { message, run_dir }) = *command else {
        panic!("expected Resume command");
    };
    assert_eq!(message.as_deref(), Some("Recovered from stop"));
    assert_eq!(run_dir.run_id.as_deref(), Some("r01"));
    assert_eq!(run_dir.run_root.as_deref(), Some(Path::new("/tmp/runs")));
}

#[test]
fn parse_run_doctor_command() {
    let cli = Cli::try_parse_from([
        "harness",
        "run",
        "doctor",
        "--json",
        "--run-id",
        "r01",
        "--run-root",
        "/tmp/runs",
    ])
    .unwrap();
    let Command::Run { command } = cli.command else {
        panic!("expected Run command");
    };
    let RunCommand::Doctor(DoctorArgs { json, run_dir }) = *command else {
        panic!("expected Doctor command");
    };
    assert!(json);
    assert_eq!(run_dir.run_id.as_deref(), Some("r01"));
    assert_eq!(run_dir.run_root.as_deref(), Some(Path::new("/tmp/runs")));
}

#[test]
fn parse_run_repair_command() {
    let cli = Cli::try_parse_from(["harness", "run", "repair", "--run-dir", "/tmp/run"]).unwrap();
    let Command::Run { command } = cli.command else {
        panic!("expected Run command");
    };
    let RunCommand::Repair(RepairArgs { json, run_dir }) = *command else {
        panic!("expected Repair command");
    };
    assert!(!json);
    assert_eq!(run_dir.run_dir.as_deref(), Some(Path::new("/tmp/run")));
}

#[test]
fn parse_cluster_with_extra_names() {
    let cli = Cli::try_parse_from([
        "harness",
        "setup",
        "kuma",
        "cluster",
        "global-zone-up",
        "global",
        "zone1",
        "zone2",
    ])
    .unwrap();
    let args = expect_cluster_args(cli.command);
    assert_eq!(args.mode, "global-zone-up");
    assert_eq!(args.cluster_name, "global");
    assert_eq!(args.extra_cluster_names, vec!["zone1", "zone2"]);
}

#[test]
fn parse_remote_cluster_provider_with_targets() {
    let cli = Cli::try_parse_from([
        "harness",
        "setup",
        "kuma",
        "cluster",
        "--provider",
        "remote",
        "--remote",
        "name=kuma-1,kubeconfig=/tmp/global.yaml,context=global",
        "--remote",
        "name=kuma-2,kubeconfig=/tmp/zone.yaml",
        "--push-prefix",
        "ghcr.io/acme/kuma",
        "--push-tag",
        "pr-123",
        "global-zone-up",
        "kuma-1",
        "kuma-2",
        "zone-1",
    ])
    .unwrap();
    let args = expect_cluster_args(cli.command);
    assert_remote_cluster_args(&args);
}

#[test]
fn parse_setup_gateway_uninstall() {
    let cli = Cli::try_parse_from([
        "harness",
        "setup",
        "gateway",
        "--kubeconfig",
        "/tmp/kubeconfig.yaml",
        "--uninstall",
    ])
    .unwrap();
    match cli.command {
        Command::Setup {
            command:
                SetupCommand::Gateway(GatewayArgs {
                    kubeconfig,
                    repo_root,
                    check_only,
                    uninstall,
                }),
        } => {
            assert_eq!(kubeconfig.as_deref(), Some("/tmp/kubeconfig.yaml"));
            assert!(repo_root.is_none());
            assert!(!check_only);
            assert!(uninstall);
        }
        _ => panic!("expected Gateway command"),
    }
}

#[test]
fn parse_setup_capabilities_with_scope_overrides() {
    let cli = Cli::try_parse_from([
        "harness",
        "setup",
        "capabilities",
        "--project-dir",
        "/tmp/project",
        "--repo-root",
        "/tmp/repo",
    ])
    .unwrap();
    match cli.command {
        Command::Setup {
            command:
                SetupCommand::Capabilities(CapabilitiesArgs {
                    project_dir,
                    repo_root,
                }),
        } => {
            assert_eq!(project_dir.as_deref(), Some("/tmp/project"));
            assert_eq!(repo_root.as_deref(), Some("/tmp/repo"));
        }
        _ => panic!("expected Capabilities command"),
    }
}

#[test]
fn parse_observe_doctor() {
    let cli = Cli::try_parse_from([
        "harness",
        "observe",
        "doctor",
        "--json",
        "--project-dir",
        "/tmp/project",
    ])
    .unwrap();
    match cli.command {
        Command::Observe(args) => {
            let ObserveArgs {
                agent,
                observe_id,
                mode: ObserveMode::Doctor { json, project_dir },
            } = *args
            else {
                panic!("expected Doctor mode");
            };
            assert!(agent.is_none());
            assert_eq!(observe_id, "project-default");
            assert!(json);
            assert_eq!(project_dir.as_deref(), Some("/tmp/project"));
        }
        _ => panic!("expected Observe Doctor command"),
    }
}

#[test]
fn parse_observe_scope_flags() {
    let cli = Cli::try_parse_from([
        "harness",
        "observe",
        "--agent",
        "codex",
        "--observe-id",
        "shared-ledger",
        "doctor",
        "--json",
    ])
    .unwrap();
    match cli.command {
        Command::Observe(args) => {
            let ObserveArgs {
                agent,
                observe_id,
                mode: ObserveMode::Doctor { json, project_dir },
            } = *args
            else {
                panic!("expected Doctor mode");
            };
            assert_eq!(agent, Some(HookAgent::Codex));
            assert_eq!(observe_id, "shared-ledger");
            assert!(json);
            assert!(project_dir.is_none());
        }
        _ => panic!("expected Observe Doctor command with scope flags"),
    }
}

#[test]
fn reject_legacy_observe_scan_doctor_action() {
    let error = Cli::try_parse_from(["harness", "observe", "scan", "--action", "doctor"])
        .expect_err("legacy doctor action should fail");
    assert_eq!(error.kind(), ErrorKind::InvalidValue);
}

#[test]
fn parse_top_level_session_start() {
    let cli =
        Cli::try_parse_from(["harness", "session-start", "--project-dir", "/tmp/project"]).unwrap();
    match cli.command {
        Command::SessionStart(SessionStartArgs { project_dir }) => {
            assert_eq!(project_dir.as_deref(), Some("/tmp/project"));
        }
        _ => panic!("expected top-level SessionStart command"),
    }
}

#[test]
fn parse_top_level_session_stop() {
    let cli =
        Cli::try_parse_from(["harness", "session-stop", "--project-dir", "/tmp/project"]).unwrap();
    match cli.command {
        Command::SessionStop(SessionStopArgs { project_dir }) => {
            assert_eq!(project_dir.as_deref(), Some("/tmp/project"));
        }
        _ => panic!("expected top-level SessionStop command"),
    }
}

#[test]
fn parse_session_observe_with_actor() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "observe",
        "sess-1",
        "--poll-interval",
        "5",
        "--json",
        "--actor",
        "claude-leader",
        "--project-dir",
        "/tmp/project",
    ])
    .unwrap();
    match cli.command {
        Command::Session {
            command:
                SessionCommand::Observe(SessionObserveArgs {
                    session_id,
                    poll_interval,
                    json,
                    actor,
                    project_dir,
                }),
        } => {
            assert_eq!(session_id, "sess-1");
            assert_eq!(poll_interval, 5);
            assert!(json);
            assert_eq!(actor.as_deref(), Some("claude-leader"));
            assert_eq!(project_dir.as_deref(), Some("/tmp/project"));
        }
        _ => panic!("expected Session observe command"),
    }
}

#[test]
fn parse_top_level_pre_compact() {
    let cli =
        Cli::try_parse_from(["harness", "pre-compact", "--project-dir", "/tmp/project"]).unwrap();
    match cli.command {
        Command::PreCompact(PreCompactArgs { project_dir }) => {
            assert_eq!(project_dir.as_deref(), Some("/tmp/project"));
        }
        _ => panic!("expected top-level PreCompact command"),
    }
}

#[test]
fn parse_daemon_stop() {
    let cli = Cli::try_parse_from(["harness", "daemon", "stop"]).unwrap();
    match cli.command {
        Command::Daemon {
            command: DaemonCommand::Stop(args),
        } => assert!(!args.json),
        _ => panic!("expected daemon stop command"),
    }
}

#[test]
fn parse_daemon_dev() {
    let cli = Cli::try_parse_from(["harness", "daemon", "dev"]).unwrap();
    match cli.command {
        Command::Daemon {
            command: DaemonCommand::Dev(args),
        } => {
            assert_eq!(args.host, "127.0.0.1");
            assert_eq!(args.port, 0);
            assert_eq!(args.app_group_id, HARNESS_MONITOR_APP_GROUP_ID);
            assert!(args.codex_ws_url.is_none());
        }
        _ => panic!("expected daemon dev command"),
    }
}

#[test]
fn parse_daemon_stop_json() {
    let cli = Cli::try_parse_from(["harness", "daemon", "stop", "--json"]).unwrap();
    match cli.command {
        Command::Daemon {
            command: DaemonCommand::Stop(args),
        } => assert!(args.json),
        _ => panic!("expected daemon stop command"),
    }
}

#[test]
fn parse_daemon_restart() {
    let cli = Cli::try_parse_from(["harness", "daemon", "restart"]).unwrap();
    match cli.command {
        Command::Daemon {
            command: DaemonCommand::Restart(args),
        } => assert!(!args.json),
        _ => panic!("expected daemon restart command"),
    }
}

#[test]
fn parse_daemon_restart_json() {
    let cli = Cli::try_parse_from(["harness", "daemon", "restart", "--json"]).unwrap();
    match cli.command {
        Command::Daemon {
            command: DaemonCommand::Restart(args),
        } => assert!(args.json),
        _ => panic!("expected daemon restart command"),
    }
}

#[test]
fn parse_bridge_start_defaults_to_all_capabilities() {
    let cli = Cli::try_parse_from(["harness", "bridge", "start"]).unwrap();
    match cli.command {
        Command::Bridge {
            command: BridgeCommand::Start(args),
        } => {
            assert!(args.config.capabilities.is_empty());
            assert!(!args.daemon);
        }
        _ => panic!("expected bridge start command"),
    }
}

#[test]
fn parse_bridge_start_with_explicit_capabilities() {
    let cli = Cli::try_parse_from([
        "harness",
        "bridge",
        "start",
        "--daemon",
        "--capability",
        "codex",
        "--capability",
        "agent-tui",
        "--codex-port",
        "14500",
        "--codex-path",
        "/tmp/mock-codex",
    ])
    .unwrap();
    match cli.command {
        Command::Bridge {
            command: BridgeCommand::Start(args),
        } => {
            assert!(args.daemon);
            assert_eq!(
                args.config.capabilities,
                vec![BridgeCapability::Codex, BridgeCapability::AgentTui]
            );
            assert_eq!(args.config.codex_port, Some(14500));
            assert_eq!(
                args.config.codex_path.as_deref(),
                Some(Path::new("/tmp/mock-codex"))
            );
        }
        _ => panic!("expected bridge start command"),
    }
}

#[test]
fn parse_bridge_reconfigure_enable_and_disable() {
    let cli = Cli::try_parse_from([
        "harness",
        "bridge",
        "reconfigure",
        "--enable",
        "codex",
        "--disable",
        "agent-tui",
        "--force",
        "--json",
    ])
    .unwrap();
    match cli.command {
        Command::Bridge {
            command: BridgeCommand::Reconfigure(args),
        } => {
            assert_eq!(args.enable, vec![BridgeCapability::Codex]);
            assert_eq!(args.disable, vec![BridgeCapability::AgentTui]);
            assert!(args.force);
            assert!(args.json);
        }
        _ => panic!("expected bridge reconfigure command"),
    }
}

#[test]
fn parse_agents_prompt_submit() {
    let cli = Cli::try_parse_from([
        "harness",
        "agents",
        "prompt-submit",
        "--agent",
        "codex",
        "--project-dir",
        "/tmp/project",
    ])
    .unwrap();
    match cli.command {
        Command::Agents {
            command:
                AgentsCommand::PromptSubmit(AgentPromptSubmitArgs {
                    agent,
                    project_dir,
                    session_id,
                }),
        } => {
            assert_eq!(agent, HookAgent::Codex);
            assert_eq!(project_dir.as_deref(), Some("/tmp/project"));
            assert!(session_id.is_none());
        }
        _ => panic!("expected agents prompt-submit command"),
    }
}

#[test]
fn reject_grouped_lifecycle_commands_under_setup() {
    for argv in [
        vec![
            "harness",
            "setup",
            "session-start",
            "--project-dir",
            "/tmp/project",
        ],
        vec![
            "harness",
            "setup",
            "session-stop",
            "--project-dir",
            "/tmp/project",
        ],
        vec![
            "harness",
            "setup",
            "pre-compact",
            "--project-dir",
            "/tmp/project",
        ],
    ] {
        let error = Cli::try_parse_from(argv).expect_err("grouped lifecycle form should fail");
        assert_eq!(error.kind(), ErrorKind::InvalidSubcommand);
    }
}

#[test]
fn parse_apply_multiple_manifests() {
    let cli = Cli::try_parse_from([
        "harness",
        "run",
        "apply",
        "--manifest",
        "g14/02.yaml",
        "--manifest",
        "g14/01.yaml",
    ])
    .unwrap();
    let Command::Run { command } = cli.command else {
        panic!("expected Run command");
    };
    let RunCommand::Apply(ApplyArgs { manifest, .. }) = *command else {
        panic!("expected Apply command");
    };
    assert_eq!(manifest, vec!["g14/02.yaml", "g14/01.yaml"]);
}

#[test]
fn parse_envoy_capture() {
    let cli = Cli::try_parse_from([
        "harness",
        "run",
        "envoy",
        "capture",
        "--namespace",
        "kuma-demo",
        "--workload",
        "deploy/demo-client",
        "--label",
        "cap1",
    ])
    .unwrap();
    let Command::Run { command } = cli.command else {
        panic!("expected Run command");
    };
    let RunCommand::Envoy(EnvoyArgs {
        cmd:
            EnvoyCommand::Capture {
                namespace,
                workload,
                label,
                ..
            },
    }) = *command
    else {
        panic!("expected Envoy Capture command");
    };
    assert_eq!(namespace, "kuma-demo");
    assert_eq!(workload, "deploy/demo-client");
    assert_eq!(label, "cap1");
}

#[test]
fn parse_report_group() {
    let cli = Cli::try_parse_from([
        "harness",
        "run",
        "report",
        "group",
        "--group-id",
        "g01",
        "--status",
        "pass",
    ])
    .unwrap();
    let Command::Run { command } = cli.command else {
        panic!("expected Run command");
    };
    let RunCommand::Report(ReportArgs {
        cmd: ReportCommand::Group {
            group_id, status, ..
        },
    }) = *command
    else {
        panic!("expected Report Group command");
    };
    assert_eq!(group_id, "g01");
    assert_eq!(status, "pass");
}

#[test]
fn parse_runner_state_without_event() {
    let cli = Cli::try_parse_from(["harness", "run", "runner-state"]).unwrap();
    let Command::Run { command } = cli.command else {
        panic!("expected Run command");
    };
    let RunCommand::RunnerState(RunnerStateArgs { event, .. }) = *command else {
        panic!("expected RunnerState command");
    };
    assert!(event.is_none());
}

#[test]
fn parse_create_begin() {
    let cli = Cli::try_parse_from([
        "harness",
        "create",
        "begin",
        "--repo-root",
        "/repo",
        "--feature",
        "mesh-traffic",
        "--mode",
        "interactive",
        "--suite-dir",
        "/suites/mesh",
        "--suite-name",
        "mesh-suite",
    ])
    .unwrap();
    match cli.command {
        Command::Create {
            command: CreateCommand::Begin(CreateBeginArgs { feature, mode, .. }),
        } => {
            assert_eq!(feature, "mesh-traffic");
            assert_eq!(mode, "interactive");
        }
        _ => panic!("expected CreateBegin command"),
    }
}

#[test]
fn create_begin_rejects_legacy_skill_flag() {
    let result = Cli::try_parse_from([
        "harness",
        "create",
        "begin",
        "--skill",
        "suite:create",
        "--repo-root",
        "/repo",
        "--feature",
        "mesh-traffic",
        "--mode",
        "interactive",
        "--suite-dir",
        "/suites/mesh",
        "--suite-name",
        "mesh-suite",
    ]);

    assert!(result.is_err(), "legacy --skill flag should be rejected");
}

#[test]
fn parse_create_approval_begin() {
    let cli = Cli::try_parse_from([
        "harness",
        "create",
        "approval-begin",
        "--mode",
        "interactive",
        "--suite-dir",
        "/suites/mesh",
    ])
    .unwrap();

    match cli.command {
        Command::Create {
            command: CreateCommand::ApprovalBegin(ApprovalBeginArgs { mode, suite_dir }),
        } => {
            assert_eq!(mode, "interactive");
            assert_eq!(suite_dir.as_deref(), Some("/suites/mesh"));
        }
        _ => panic!("expected Create ApprovalBegin command"),
    }
}

#[test]
fn create_approval_begin_rejects_legacy_skill_flag() {
    let result = Cli::try_parse_from([
        "harness",
        "create",
        "approval-begin",
        "--skill",
        "suite:create",
        "--mode",
        "interactive",
        "--suite-dir",
        "/suites/mesh",
    ]);

    assert!(result.is_err(), "legacy --skill flag should be rejected");
}

#[test]
fn parse_create_reset() {
    let cli = Cli::try_parse_from(["harness", "create", "reset"]).unwrap();

    assert!(matches!(
        cli.command,
        Command::Create {
            command: CreateCommand::Reset(CreateResetArgs),
        }
    ));
}

#[test]
fn create_reset_rejects_legacy_skill_flag() {
    let result = Cli::try_parse_from(["harness", "create", "reset", "--skill", "suite:create"]);

    assert!(result.is_err(), "legacy --skill flag should be rejected");
}

#[test]
fn parse_restart_namespace() {
    let cli = Cli::try_parse_from([
        "harness",
        "run",
        "restart-namespace",
        "--namespace",
        "kuma-system",
    ])
    .unwrap();
    let Command::Run { command } = cli.command else {
        panic!("expected Run command");
    };
    let RunCommand::RestartNamespace(RestartNamespaceArgs { namespace, .. }) = *command else {
        panic!("expected RestartNamespace command");
    };
    assert_eq!(namespace, vec!["kuma-system"]);
}

#[test]
fn parse_kumactl_find() {
    let cli = Cli::try_parse_from(["harness", "run", "kuma", "cli", "find"]).unwrap();
    let Command::Run { command } = cli.command else {
        panic!("expected Run command");
    };
    assert!(matches!(
        *command,
        RunCommand::Kuma(KumaArgs {
            command: KumaCommand::Cli(KumactlArgs {
                cmd: KumactlCommand::Find { .. }
            })
        })
    ));
}

#[test]
fn parse_api_get() {
    let cli = Cli::try_parse_from(["harness", "run", "kuma", "api", "get", "/zones"]).unwrap();
    let Command::Run { command } = cli.command else {
        panic!("expected Run command");
    };
    let RunCommand::Kuma(KumaArgs {
        command:
            KumaCommand::Api(ApiArgs {
                method: ApiMethod::Get { path, .. },
            }),
    }) = *command
    else {
        panic!("expected Api Get command");
    };
    assert_eq!(path, "/zones");
}

#[test]
fn apply_help_describes_batch_inputs() {
    let cmd = Cli::command();
    let run_cmd = cmd
        .get_subcommands()
        .find(|s| s.get_name() == "run")
        .expect("run missing");
    let apply_cmd = run_cmd
        .get_subcommands()
        .find(|s| s.get_name() == "apply")
        .expect("apply missing");
    let manifest_arg = apply_cmd
        .get_arguments()
        .find(|a| a.get_id() == "manifest")
        .expect("manifest arg missing");
    let help = manifest_arg
        .get_help()
        .map(ToString::to_string)
        .unwrap_or_default();
    assert!(help.contains("explicit batch order"));
}

// -- Snapshot tests --

#[test]
fn snapshot_cli_help_text() {
    let mut cmd = Cli::command();
    let mut buf = Vec::new();
    cmd.write_help(&mut buf).expect("render help");
    let help = String::from_utf8(buf).expect("utf8 help");
    insta::assert_snapshot!(help);
}

#[test]
fn snapshot_cli_subcommand_list() {
    let cmd = Cli::command();
    let mut names: Vec<&str> = cmd.get_subcommands().map(clap::Command::get_name).collect();
    names.sort_unstable();
    insta::assert_snapshot!(names.join("\n"));
}

#[test]
fn parse_session_start() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "start",
        "--context",
        "test goal",
        "--runtime",
        "claude",
    ])
    .unwrap();
    match cli.command {
        Command::Session {
            command: crate::session::transport::SessionCommand::Start(args),
        } => {
            assert_eq!(args.context, "test goal");
            assert_eq!(
                args.runtime,
                Some(crate::hooks::adapters::HookAgent::Claude)
            );
        }
        _ => panic!("expected Session Start"),
    }
}

#[test]
fn parse_session_join() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "join",
        "sess-123",
        "--role",
        "worker",
        "--runtime",
        "codex",
        "--capabilities",
        "general,testing",
    ])
    .unwrap();
    match cli.command {
        Command::Session {
            command: crate::session::transport::SessionCommand::Join(args),
        } => {
            assert_eq!(args.session_id, "sess-123");
            assert_eq!(args.role, crate::session::types::SessionRole::Worker);
            assert_eq!(args.capabilities, Some("general,testing".into()));
        }
        _ => panic!("expected Session Join"),
    }
}

#[test]
fn parse_session_task_create() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "task",
        "create",
        "sess-abc",
        "--title",
        "fix bug",
        "--severity",
        "high",
        "--actor",
        "leader-1",
    ])
    .unwrap();
    match cli.command {
        Command::Session {
            command:
                crate::session::transport::SessionCommand::Task {
                    command: crate::session::transport::SessionTaskCommand::Create(args),
                },
        } => {
            assert_eq!(args.session_id, "sess-abc");
            assert_eq!(args.title, "fix bug");
            assert_eq!(args.severity, crate::session::types::TaskSeverity::High);
        }
        _ => panic!("expected Session Task Create"),
    }
}

#[test]
fn parse_session_observe_with_poll() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "observe",
        "sess-watch",
        "--poll-interval",
        "5",
        "--json",
    ])
    .unwrap();
    match cli.command {
        Command::Session {
            command: crate::session::transport::SessionCommand::Observe(args),
        } => {
            assert_eq!(args.session_id, "sess-watch");
            assert_eq!(args.poll_interval, 5);
            assert!(args.json);
        }
        _ => panic!("expected Session Observe"),
    }
}

#[test]
fn parse_session_end() {
    let cli = Cli::try_parse_from(["harness", "session", "end", "sess-x", "--actor", "leader-1"])
        .unwrap();
    let Command::Session {
        command: crate::session::transport::SessionCommand::End(args),
    } = cli.command
    else {
        panic!("expected Session End");
    };
    assert_eq!(args.session_id, "sess-x");
    assert_eq!(args.actor, "leader-1");
}

#[test]
fn parse_session_assign() {
    let cli = Cli::try_parse_from([
        "harness", "session", "assign", "sess-a", "agent-1", "--role", "reviewer", "--actor",
        "leader-1",
    ])
    .unwrap();
    let Command::Session {
        command: crate::session::transport::SessionCommand::Assign(args),
    } = cli.command
    else {
        panic!("expected Session Assign");
    };
    assert_eq!(args.agent_id, "agent-1");
    assert_eq!(args.role, crate::session::types::SessionRole::Reviewer);
}

#[test]
fn parse_session_remove() {
    let cli = Cli::try_parse_from([
        "harness", "session", "remove", "sess-r", "agent-2", "--actor", "leader-1",
    ])
    .unwrap();
    let Command::Session {
        command: crate::session::transport::SessionCommand::Remove(args),
    } = cli.command
    else {
        panic!("expected Session Remove");
    };
    assert_eq!(args.agent_id, "agent-2");
}

#[test]
fn parse_session_transfer_leader() {
    let cli = Cli::try_parse_from([
        "harness",
        "session",
        "transfer-leader",
        "sess-t",
        "new-leader",
        "--reason",
        "529 errors",
        "--actor",
        "obs-1",
    ])
    .unwrap();
    let Command::Session {
        command: crate::session::transport::SessionCommand::TransferLeader(args),
    } = cli.command
    else {
        panic!("expected Session TransferLeader");
    };
    assert_eq!(args.new_leader_id, "new-leader");
    assert_eq!(args.reason, Some("529 errors".into()));
}

#[test]
fn parse_session_task_assign() {
    let cli = Cli::try_parse_from([
        "harness", "session", "task", "assign", "sess-ta", "task-1", "agent-1", "--actor",
        "leader-1",
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Task {
                command: crate::session::transport::SessionTaskCommand::Assign(args),
            },
    } = cli.command
    else {
        panic!("expected Session Task Assign");
    };
    assert_eq!(args.task_id, "task-1");
    assert_eq!(args.agent_id, "agent-1");
}

#[test]
fn parse_session_task_list() {
    let cli = Cli::try_parse_from([
        "harness", "session", "task", "list", "sess-tl", "--status", "open", "--json",
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Task {
                command: crate::session::transport::SessionTaskCommand::List(args),
            },
    } = cli.command
    else {
        panic!("expected Session Task List");
    };
    assert_eq!(args.status, Some(crate::session::types::TaskStatus::Open));
    assert!(args.json);
}

#[test]
fn parse_session_task_update() {
    let cli = Cli::try_parse_from([
        "harness", "session", "task", "update", "sess-tu", "task-1", "--status", "done", "--note",
        "fixed it", "--actor", "worker-1",
    ])
    .unwrap();
    let Command::Session {
        command:
            crate::session::transport::SessionCommand::Task {
                command: crate::session::transport::SessionTaskCommand::Update(args),
            },
    } = cli.command
    else {
        panic!("expected Session Task Update");
    };
    assert_eq!(args.status, crate::session::types::TaskStatus::Done);
    assert_eq!(args.note, Some("fixed it".into()));
}

#[test]
fn parse_session_status() {
    let cli = Cli::try_parse_from(["harness", "session", "status", "sess-s", "--json"]).unwrap();
    let Command::Session {
        command: crate::session::transport::SessionCommand::Status(args),
    } = cli.command
    else {
        panic!("expected Session Status");
    };
    assert_eq!(args.session_id, "sess-s");
    assert!(args.json);
}

#[test]
fn parse_session_list() {
    let cli = Cli::try_parse_from(["harness", "session", "list", "--json"]).unwrap();
    let Command::Session {
        command: crate::session::transport::SessionCommand::List(args),
    } = cli.command
    else {
        panic!("expected Session List");
    };
    assert!(args.json);
}
