use std::thread;
use std::time::Duration;

use clap::{Parser, Subcommand};

use crate::commands::authoring::{
    ApprovalBeginArgs, AuthoringBeginArgs, AuthoringResetArgs, AuthoringSaveArgs,
    AuthoringShowArgs, AuthoringValidateArgs,
};
use crate::commands::observe::ObserveArgs;
use crate::commands::run::{
    ApiArgs, ApplyArgs, CaptureArgs, CloseoutArgs, ClusterCheckArgs, DiffArgs, EnvoyArgs, InitArgs,
    KumactlArgs, LogsArgs, PreflightArgs, RecordArgs, ReportArgs, RestartNamespaceArgs,
    RunnerStateArgs, ServiceArgs, StatusArgs, TaskArgs, TokenArgs, ValidateArgs,
};
use crate::commands::setup::{
    BootstrapArgs, ClusterArgs, GatewayArgs, PreCompactArgs, SessionStartArgs, SessionStopArgs,
};
use crate::commands::{self, CommandContext, Execute};
use crate::errors::CliError;
use crate::hooks::{self, HookArgs};

/// Kuma test harness CLI.
#[derive(Debug, Parser)]
#[command(name = "harness", version, about = "Kuma test harness")]
pub struct Cli {
    /// Seconds to wait before executing the command. Accepts fractional
    /// values (e.g. 0.5). Use instead of `sleep N && harness ...`.
    #[arg(long, default_value = "0", global = true)]
    pub delay: f64,
    /// Subcommand to execute.
    #[command(subcommand)]
    pub command: Command,
}

/// Top-level commands.
#[derive(Debug, Subcommand)]
#[non_exhaustive]
pub enum Command {
    /// Run a harness hook for a skill.
    Hook(HookArgs),

    /// Initialize a new test run.
    #[command(alias = "init-run")]
    Init(InitArgs),

    /// Install or refresh the repo-aware harness wrapper.
    Bootstrap(BootstrapArgs),

    /// Manage disposable local k3d clusters.
    Cluster(ClusterArgs),

    /// Run preflight checks and prepare suite manifests.
    Preflight(PreflightArgs),

    /// Capture cluster pod state for a run.
    Capture(CaptureArgs),

    /// Record a tracked command.
    #[command(alias = "run", trailing_var_arg = true)]
    Record(RecordArgs),

    /// Restart deployments in specified namespaces.
    RestartNamespace(RestartNamespaceArgs),

    /// Apply manifests to the cluster.
    Apply(ApplyArgs),

    /// Validate manifests against the cluster.
    Validate(ValidateArgs),

    /// Manage runner workflow state.
    RunnerState(RunnerStateArgs),

    /// Close out a run.
    Closeout(CloseoutArgs),

    /// Report validation and group finalization.
    Report(ReportArgs),

    /// View diffs between payloads.
    Diff(DiffArgs),

    /// Envoy admin operations.
    Envoy(EnvoyArgs),

    /// Check or install Gateway API CRDs.
    Gateway(GatewayArgs),

    /// Find or build kumactl.
    Kumactl(KumactlArgs),

    /// Handle session start hook.
    SessionStart(SessionStartArgs),

    /// Handle session stop cleanup.
    SessionStop(SessionStopArgs),

    /// Save compact handoff before compaction.
    PreCompact(PreCompactArgs),

    /// Begin a suite:new workspace session.
    AuthoringBegin(AuthoringBeginArgs),

    /// Save a suite:new payload.
    AuthoringSave(AuthoringSaveArgs),

    /// Show saved suite:new payloads.
    AuthoringShow(AuthoringShowArgs),

    /// Reset suite:new workspace.
    AuthoringReset(AuthoringResetArgs),

    /// Validate authored manifests against local CRDs.
    AuthoringValidate(AuthoringValidateArgs),

    /// Begin suite:new approval flow.
    ApprovalBegin(ApprovalBeginArgs),

    /// Call the Kuma control plane REST API directly.
    Api(ApiArgs),

    /// Generate a dataplane token from the control plane (universal mode).
    Token(TokenArgs),

    /// Manage universal mode test service containers.
    Service(ServiceArgs),

    /// Show cluster state as structured JSON.
    Status(StatusArgs),

    /// Show container logs.
    Logs(LogsArgs),

    /// Check if cluster containers are still running.
    ClusterCheck(ClusterCheckArgs),

    /// Read or wait for background task output.
    Task(TaskArgs),

    /// Report harness capabilities for skill planning.
    Capabilities,

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
        // Setup commands
        Command::Init(args) => args.execute(&ctx),
        Command::Bootstrap(args) => args.execute(&ctx),
        Command::Cluster(args) => args.execute(&ctx),
        Command::Gateway(args) => args.execute(&ctx),
        Command::SessionStart(args) => args.execute(&ctx),
        Command::SessionStop(args) => args.execute(&ctx),
        Command::PreCompact(args) => args.execute(&ctx),
        Command::Capabilities => commands::setup::capabilities(),
        Command::Observe(args) => args.execute(&ctx),
        // Run commands
        Command::Capture(args) => args.execute(&ctx),
        Command::Record(args) => args.execute(&ctx),
        Command::Apply(args) => args.execute(&ctx),
        Command::Validate(args) => args.execute(&ctx),
        Command::Preflight(args) => args.execute(&ctx),
        Command::RunnerState(args) => args.execute(&ctx),
        Command::Closeout(args) => args.execute(&ctx),
        Command::Report(args) => args.execute(&ctx),
        Command::Diff(args) => args.execute(&ctx),
        Command::Envoy(args) => args.execute(&ctx),
        Command::Kumactl(args) => args.execute(&ctx),
        Command::Api(args) => args.execute(&ctx),
        Command::Token(args) => args.execute(&ctx),
        Command::Service(args) => args.execute(&ctx),
        Command::Status(args) => args.execute(&ctx),
        Command::Logs(args) => args.execute(&ctx),
        Command::ClusterCheck(args) => args.execute(&ctx),
        Command::Task(args) => args.execute(&ctx),
        Command::RestartNamespace(args) => args.execute(&ctx),
        // Authoring commands
        Command::AuthoringBegin(args) => args.execute(&ctx),
        Command::AuthoringSave(args) => args.execute(&ctx),
        Command::AuthoringShow(args) => args.execute(&ctx),
        Command::AuthoringReset(args) => args.execute(&ctx),
        Command::AuthoringValidate(args) => args.execute(&ctx),
        Command::ApprovalBegin(args) => args.execute(&ctx),
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
            "api",
            "apply",
            "approval-begin",
            "authoring-begin",
            "authoring-reset",
            "authoring-save",
            "authoring-show",
            "authoring-validate",
            "bootstrap",
            "capture",
            "closeout",
            "cluster",
            "cluster-check",
            "diff",
            "envoy",
            "gateway",
            "hook",
            "init",
            "kumactl",
            "logs",
            "observe",
            "pre-compact",
            "preflight",
            "record",
            "report",
            "restart-namespace",
            "runner-state",
            "service",
            "session-start",
            "session-stop",
            "status",
            "task",
            "token",
            "validate",
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
            Command::Init(InitArgs {
                suite,
                run_id,
                profile,
                repo_root,
                run_root,
            }) => {
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
            Command::Record(RecordArgs { label, command, .. }) => {
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
            "cluster",
            "global-zone-up",
            "global",
            "zone1",
            "zone2",
        ])
        .unwrap();
        match cli.command {
            Command::Cluster(ClusterArgs {
                mode,
                cluster_name,
                extra_cluster_names,
                ..
            }) => {
                assert_eq!(mode, "global-zone-up");
                assert_eq!(cluster_name, "global");
                assert_eq!(extra_cluster_names, vec!["zone1", "zone2"]);
            }
            _ => panic!("expected Cluster command"),
        }
    }

    #[test]
    fn parse_apply_multiple_manifests() {
        let cli = Cli::try_parse_from([
            "harness",
            "apply",
            "--manifest",
            "g14/02.yaml",
            "--manifest",
            "g14/01.yaml",
        ])
        .unwrap();
        match cli.command {
            Command::Apply(ApplyArgs { manifest, .. }) => {
                assert_eq!(manifest, vec!["g14/02.yaml", "g14/01.yaml"]);
            }
            _ => panic!("expected Apply command"),
        }
    }

    #[test]
    fn parse_envoy_capture() {
        let cli = Cli::try_parse_from([
            "harness",
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
            Command::Envoy(EnvoyArgs {
                cmd:
                    commands::run::EnvoyCommand::Capture {
                        namespace,
                        workload,
                        label,
                        ..
                    },
            }) => {
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
            "report",
            "group",
            "--group-id",
            "g01",
            "--status",
            "pass",
        ])
        .unwrap();
        match cli.command {
            Command::Report(ReportArgs {
                cmd:
                    commands::run::ReportCommand::Group {
                        group_id, status, ..
                    },
            }) => {
                assert_eq!(group_id, "g01");
                assert_eq!(status, "pass");
            }
            _ => panic!("expected Report Group command"),
        }
    }

    #[test]
    fn parse_runner_state_without_event() {
        let cli = Cli::try_parse_from(["harness", "runner-state"]).unwrap();
        match cli.command {
            Command::RunnerState(RunnerStateArgs { event, .. }) => {
                assert!(event.is_none());
            }
            _ => panic!("expected RunnerState command"),
        }
    }

    #[test]
    fn parse_authoring_begin() {
        let cli = Cli::try_parse_from([
            "harness",
            "authoring-begin",
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
            Command::AuthoringBegin(AuthoringBeginArgs {
                skill,
                feature,
                mode,
                ..
            }) => {
                assert_eq!(skill, "suite:new");
                assert_eq!(feature, "mesh-traffic");
                assert_eq!(mode, "interactive");
            }
            _ => panic!("expected AuthoringBegin command"),
        }
    }

    #[test]
    fn parse_restart_namespace() {
        let cli =
            Cli::try_parse_from(["harness", "restart-namespace", "--namespace", "kuma-system"])
                .unwrap();
        match cli.command {
            Command::RestartNamespace(RestartNamespaceArgs { namespace, .. }) => {
                assert_eq!(namespace, vec!["kuma-system"]);
            }
            _ => panic!("expected RestartNamespace command"),
        }
    }

    #[test]
    fn parse_kumactl_find() {
        let cli = Cli::try_parse_from(["harness", "kumactl", "find"]).unwrap();
        assert!(matches!(
            cli.command,
            Command::Kumactl(KumactlArgs {
                cmd: commands::run::KumactlCommand::Find { .. }
            })
        ));
    }

    #[test]
    fn parse_api_get() {
        let cli = Cli::try_parse_from(["harness", "api", "get", "/zones"]).unwrap();
        match cli.command {
            Command::Api(ApiArgs {
                method: commands::run::ApiMethod::Get { path, .. },
            }) => assert_eq!(path, "/zones"),
            _ => panic!("expected Api Get command"),
        }
    }

    #[test]
    fn apply_help_describes_batch_inputs() {
        let cmd = Cli::command();
        let apply_cmd = cmd
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
}
