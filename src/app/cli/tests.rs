use super::*;
use crate::run::{
    ApiArgs, ApiMethod, EnvoyCommand, FinishArgs, KumaCommand, KumactlArgs, KumactlCommand,
    ReportCommand, ResumeArgs, StartArgs,
};
use crate::setup::{ClusterArgs, KumaSetupCommand};
use clap::{CommandFactory, error::ErrorKind};
use std::path::Path;

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
        "guard-bash",
        "guard-write",
        "guard-question",
        "guard-stop",
        "verify-bash",
        "verify-write",
        "verify-question",
        "audit",
        "enrich-failure",
        "context-agent",
        "validate-agent",
    ] {
        assert!(hook_names.contains(&expected), "missing hook: {expected}");
    }
}

#[test]
fn parse_hook_command() {
    let cli = Cli::try_parse_from(["harness", "hook", "suite:run", "guard-bash"]).unwrap();
    match cli.command {
        Command::Hook(HookArgs { skill, hook, .. }) => {
            assert_eq!(skill, "suite:run");
            assert_eq!(hook.name(), "guard-bash");
        }
        _ => panic!("expected Hook command"),
    }
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
    match cli.command {
        Command::Run {
            command:
                RunCommand::Init(InitArgs {
                    suite,
                    run_id,
                    profile,
                    repo_root,
                    run_root,
                }),
        } => {
            assert_eq!(suite, "suite.md");
            assert_eq!(run_id, "r01");
            assert_eq!(profile, "single-zone");
            assert!(repo_root.is_none());
            assert!(run_root.is_none());
        }
        _ => panic!("expected Init command"),
    }
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
    match cli.command {
        Command::Run {
            command:
                RunCommand::Start(StartArgs {
                    suite,
                    run_id,
                    profile,
                    repo_root,
                    run_root,
                }),
        } => {
            assert_eq!(suite, "suite.md");
            assert!(run_id.is_none());
            assert_eq!(profile, "single-zone");
            assert_eq!(repo_root.as_deref(), Some("/repo"));
            assert!(run_root.is_none());
        }
        _ => panic!("expected Start command"),
    }
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
    match cli.command {
        Command::Run {
            command: RunCommand::Record(RecordArgs { label, command, .. }),
        } => {
            assert_eq!(label.as_deref(), Some("test"));
            assert_eq!(command, vec!["kubectl", "get", "pods", "-n", "kuma-system"]);
        }
        _ => panic!("expected Record command"),
    }
}

#[test]
fn parse_finish_command() {
    let cli = Cli::try_parse_from(["harness", "run", "finish", "--run-dir", "/tmp/run"]).unwrap();
    match cli.command {
        Command::Run {
            command: RunCommand::Finish(FinishArgs { run_dir }),
        } => {
            assert_eq!(run_dir.run_dir.as_deref(), Some(Path::new("/tmp/run")));
            assert!(run_dir.run_id.is_none());
            assert!(run_dir.run_root.is_none());
        }
        _ => panic!("expected Finish command"),
    }
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
    match cli.command {
        Command::Run {
            command: RunCommand::Resume(ResumeArgs { message, run_dir }),
        } => {
            assert_eq!(message.as_deref(), Some("Recovered from stop"));
            assert_eq!(run_dir.run_id.as_deref(), Some("r01"));
            assert_eq!(run_dir.run_root.as_deref(), Some(Path::new("/tmp/runs")));
        }
        _ => panic!("expected Resume command"),
    }
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
    match cli.command {
        Command::Setup {
            command:
                SetupCommand::Kuma(KumaSetupArgs {
                    command:
                        KumaSetupCommand::Cluster(ClusterArgs {
                            mode,
                            cluster_name,
                            extra_cluster_names,
                            ..
                        }),
                }),
        } => {
            assert_eq!(mode, "global-zone-up");
            assert_eq!(cluster_name, "global");
            assert_eq!(extra_cluster_names, vec!["zone1", "zone2"]);
        }
        _ => panic!("expected Cluster command"),
    }
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
    match cli.command {
        Command::Run {
            command: RunCommand::Apply(ApplyArgs { manifest, .. }),
        } => {
            assert_eq!(manifest, vec!["g14/02.yaml", "g14/01.yaml"]);
        }
        _ => panic!("expected Apply command"),
    }
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
    match cli.command {
        Command::Run {
            command:
                RunCommand::Envoy(EnvoyArgs {
                    cmd:
                        EnvoyCommand::Capture {
                            namespace,
                            workload,
                            label,
                            ..
                        },
                }),
        } => {
            assert_eq!(namespace, "kuma-demo");
            assert_eq!(workload, "deploy/demo-client");
            assert_eq!(label, "cap1");
        }
        _ => panic!("expected Envoy Capture command"),
    }
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
    match cli.command {
        Command::Run {
            command:
                RunCommand::Report(ReportArgs {
                    cmd:
                        ReportCommand::Group {
                            group_id, status, ..
                        },
                }),
        } => {
            assert_eq!(group_id, "g01");
            assert_eq!(status, "pass");
        }
        _ => panic!("expected Report Group command"),
    }
}

#[test]
fn parse_runner_state_without_event() {
    let cli = Cli::try_parse_from(["harness", "run", "runner-state"]).unwrap();
    match cli.command {
        Command::Run {
            command: RunCommand::RunnerState(RunnerStateArgs { event, .. }),
        } => {
            assert!(event.is_none());
        }
        _ => panic!("expected RunnerState command"),
    }
}

#[test]
fn parse_create_begin() {
    let cli = Cli::try_parse_from([
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
    ])
    .unwrap();
    match cli.command {
        Command::Create {
            command:
                CreateCommand::Begin(CreateBeginArgs {
                    skill,
                    feature,
                    mode,
                    ..
                }),
        } => {
            assert_eq!(skill, "suite:create");
            assert_eq!(feature, "mesh-traffic");
            assert_eq!(mode, "interactive");
        }
        _ => panic!("expected CreateBegin command"),
    }
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
    match cli.command {
        Command::Run {
            command: RunCommand::RestartNamespace(RestartNamespaceArgs { namespace, .. }),
        } => {
            assert_eq!(namespace, vec!["kuma-system"]);
        }
        _ => panic!("expected RestartNamespace command"),
    }
}

#[test]
fn parse_kumactl_find() {
    let cli = Cli::try_parse_from(["harness", "run", "kuma", "cli", "find"]).unwrap();
    assert!(matches!(
        cli.command,
        Command::Run {
            command: RunCommand::Kuma(KumaArgs {
                command: KumaCommand::Cli(KumactlArgs {
                    cmd: KumactlCommand::Find { .. }
                })
            })
        }
    ));
}

#[test]
fn parse_api_get() {
    let cli = Cli::try_parse_from(["harness", "run", "kuma", "api", "get", "/zones"]).unwrap();
    match cli.command {
        Command::Run {
            command:
                RunCommand::Kuma(KumaArgs {
                    command:
                        KumaCommand::Api(ApiArgs {
                            method: ApiMethod::Get { path, .. },
                        }),
                }),
        } => assert_eq!(path, "/zones"),
        _ => panic!("expected Api Get command"),
    }
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
