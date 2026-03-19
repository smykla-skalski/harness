use std::thread;
use std::time::Duration;

use clap::{Parser, Subcommand};

use crate::app::command_context::{CommandContext, Execute};
use crate::authoring::commands::{
    ApprovalBeginArgs, AuthoringBeginArgs, AuthoringResetArgs, AuthoringSaveArgs,
    AuthoringShowArgs, AuthoringValidateArgs,
};
use crate::errors::CliError;
use crate::hooks::{self, HookArgs};
use crate::observe::ObserveArgs;
#[cfg(test)]
use crate::run::commands::{ApiArgs, KumactlArgs};
use crate::run::commands::{
    ApplyArgs, CaptureArgs, CloseoutArgs, ClusterCheckArgs, DiffArgs, EnvoyArgs, InitArgs,
    KumaArgs, LogsArgs, PreflightArgs, RecordArgs, ReportArgs, RestartNamespaceArgs,
    RunnerStateArgs, StatusArgs, TaskArgs, ValidateArgs,
};
use crate::setup;
#[cfg(test)]
use crate::setup::ClusterArgs;
use crate::setup::{
    BootstrapArgs, GatewayArgs, KumaSetupArgs, PreCompactArgs, SessionStartArgs, SessionStopArgs,
};

/// Harness CLI.
#[derive(Debug, Parser)]
#[command(name = "harness", version, about = "Harness CLI")]
pub struct Cli {
    /// Seconds to wait before executing the command. Accepts fractional
    /// values (e.g. 0.5). Use instead of `sleep N && harness ...`.
    #[arg(long, default_value = "0", global = true)]
    pub delay: f64,
    /// Subcommand to execute.
    #[command(subcommand)]
    pub command: Command,
}

/// Grouped `run` commands.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum RunCommand {
    Init(InitArgs),
    Preflight(PreflightArgs),
    Capture(CaptureArgs),
    Record(RecordArgs),
    RestartNamespace(RestartNamespaceArgs),
    Apply(ApplyArgs),
    Validate(ValidateArgs),
    RunnerState(RunnerStateArgs),
    Closeout(CloseoutArgs),
    Report(ReportArgs),
    Diff(DiffArgs),
    Envoy(EnvoyArgs),
    Kuma(KumaArgs),
    Status(StatusArgs),
    Logs(LogsArgs),
    ClusterCheck(ClusterCheckArgs),
    Task(TaskArgs),
}

/// Grouped `authoring` commands.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum AuthoringCommand {
    Begin(AuthoringBeginArgs),
    Save(AuthoringSaveArgs),
    Show(AuthoringShowArgs),
    Reset(AuthoringResetArgs),
    Validate(AuthoringValidateArgs),
    ApprovalBegin(ApprovalBeginArgs),
}

/// Grouped `setup` commands.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum SetupCommand {
    Bootstrap(BootstrapArgs),
    Kuma(KumaSetupArgs),
    Gateway(GatewayArgs),
    SessionStart(SessionStartArgs),
    SessionStop(SessionStopArgs),
    PreCompact(PreCompactArgs),
    Capabilities,
}

/// Top-level commands.
#[derive(Debug, Subcommand)]
#[non_exhaustive]
pub enum Command {
    /// Run a harness hook for a skill.
    Hook(HookArgs),

    /// Suite:run commands grouped by domain.
    Run {
        #[command(subcommand)]
        command: RunCommand,
    },

    /// Suite:new commands grouped by domain.
    Authoring {
        #[command(subcommand)]
        command: AuthoringCommand,
    },

    /// Setup and session lifecycle commands.
    Setup {
        #[command(subcommand)]
        command: SetupCommand,
    },

    /// Handle session start hook.
    SessionStart(SessionStartArgs),

    /// Handle session stop cleanup.
    SessionStop(SessionStopArgs),

    /// Save compact handoff before compaction.
    PreCompact(PreCompactArgs),

    /// Observe and classify Claude Code session logs.
    Observe(ObserveArgs),
}

/// Dispatch a parsed command to its owning subsystem.
///
/// # Errors
/// Returns `CliError` when the selected command fails.
pub fn dispatch(command: &Command) -> Result<i32, CliError> {
    let ctx = CommandContext::production();
    match command {
        Command::Hook(_) => unreachable!("hooks are handled separately"),
        Command::Run { command } => dispatch_run(&ctx, command),
        Command::Authoring { command } => dispatch_authoring(&ctx, command),
        Command::Setup { command } => dispatch_setup(&ctx, command),
        Command::SessionStart(args) => args.execute(&ctx),
        Command::SessionStop(args) => args.execute(&ctx),
        Command::PreCompact(args) => args.execute(&ctx),
        Command::Observe(args) => args.execute(&ctx),
    }
}

fn dispatch_run(ctx: &CommandContext, command: &RunCommand) -> Result<i32, CliError> {
    match command {
        RunCommand::Init(args) => args.execute(ctx),
        RunCommand::Preflight(args) => args.execute(ctx),
        RunCommand::Capture(args) => args.execute(ctx),
        RunCommand::Record(args) => args.execute(ctx),
        RunCommand::RestartNamespace(args) => args.execute(ctx),
        RunCommand::Apply(args) => args.execute(ctx),
        RunCommand::Validate(args) => args.execute(ctx),
        RunCommand::RunnerState(args) => args.execute(ctx),
        RunCommand::Closeout(args) => args.execute(ctx),
        RunCommand::Report(args) => args.execute(ctx),
        RunCommand::Diff(args) => args.execute(ctx),
        RunCommand::Envoy(args) => args.execute(ctx),
        RunCommand::Kuma(args) => args.execute(ctx),
        RunCommand::Status(args) => args.execute(ctx),
        RunCommand::Logs(args) => args.execute(ctx),
        RunCommand::ClusterCheck(args) => args.execute(ctx),
        RunCommand::Task(args) => args.execute(ctx),
    }
}

fn dispatch_authoring(ctx: &CommandContext, command: &AuthoringCommand) -> Result<i32, CliError> {
    match command {
        AuthoringCommand::Begin(args) => args.execute(ctx),
        AuthoringCommand::Save(args) => args.execute(ctx),
        AuthoringCommand::Show(args) => args.execute(ctx),
        AuthoringCommand::Reset(args) => args.execute(ctx),
        AuthoringCommand::Validate(args) => args.execute(ctx),
        AuthoringCommand::ApprovalBegin(args) => args.execute(ctx),
    }
}

fn dispatch_setup(ctx: &CommandContext, command: &SetupCommand) -> Result<i32, CliError> {
    match command {
        SetupCommand::Bootstrap(args) => args.execute(ctx),
        SetupCommand::Kuma(args) => args.execute(ctx),
        SetupCommand::Gateway(args) => args.execute(ctx),
        SetupCommand::SessionStart(args) => args.execute(ctx),
        SetupCommand::SessionStop(args) => args.execute(ctx),
        SetupCommand::PreCompact(args) => args.execute(ctx),
        SetupCommand::Capabilities => setup::capabilities(),
    }
}

/// Parse CLI arguments and run the appropriate command.
///
/// # Errors
/// Returns `CliError` on command failure. Hook errors are handled internally
/// and never surface as `CliError`.
pub fn run() -> Result<i32, CliError> {
    let cli = Cli::parse();
    if cli.delay > 0.0 {
        thread::sleep(Duration::from_secs_f64(cli.delay));
    }
    match cli.command {
        Command::Hook(ref args) => Ok(hooks::run_hook_command(args.agent, &args.skill, &args.hook)),
        ref other => dispatch(other),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    #[test]
    fn all_expected_subcommands_registered() {
        let cmd = Cli::command();
        let names: Vec<&str> = cmd.get_subcommands().map(clap::Command::get_name).collect();
        for expected in [
            "authoring",
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
                            crate::setup::KumaSetupCommand::Cluster(ClusterArgs {
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
    fn parse_legacy_top_level_session_start() {
        let cli =
            Cli::try_parse_from(["harness", "session-start", "--project-dir", "/tmp/project"])
                .unwrap();
        match cli.command {
            Command::SessionStart(SessionStartArgs { project_dir }) => {
                assert_eq!(project_dir.as_deref(), Some("/tmp/project"));
            }
            _ => panic!("expected top-level SessionStart command"),
        }
    }

    #[test]
    fn parse_legacy_top_level_session_stop() {
        let cli = Cli::try_parse_from(["harness", "session-stop", "--project-dir", "/tmp/project"])
            .unwrap();
        match cli.command {
            Command::SessionStop(SessionStopArgs { project_dir }) => {
                assert_eq!(project_dir.as_deref(), Some("/tmp/project"));
            }
            _ => panic!("expected top-level SessionStop command"),
        }
    }

    #[test]
    fn parse_legacy_top_level_pre_compact() {
        let cli = Cli::try_parse_from(["harness", "pre-compact", "--project-dir", "/tmp/project"])
            .unwrap();
        match cli.command {
            Command::PreCompact(PreCompactArgs { project_dir }) => {
                assert_eq!(project_dir.as_deref(), Some("/tmp/project"));
            }
            _ => panic!("expected top-level PreCompact command"),
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
                            crate::run::commands::EnvoyCommand::Capture {
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
                            crate::run::commands::ReportCommand::Group {
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
    fn parse_authoring_begin() {
        let cli = Cli::try_parse_from([
            "harness",
            "authoring",
            "begin",
            "--skill",
            "suite:new",
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
            Command::Authoring {
                command:
                    AuthoringCommand::Begin(AuthoringBeginArgs {
                        skill,
                        feature,
                        mode,
                        ..
                    }),
            } => {
                assert_eq!(skill, "suite:new");
                assert_eq!(feature, "mesh-traffic");
                assert_eq!(mode, "interactive");
            }
            _ => panic!("expected AuthoringBegin command"),
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
                    command: crate::run::commands::KumaCommand::Cli(KumactlArgs {
                        cmd: crate::run::commands::KumactlCommand::Find { .. }
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
                            crate::run::commands::KumaCommand::Api(ApiArgs {
                                method: crate::run::commands::ApiMethod::Get { path, .. },
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
}
