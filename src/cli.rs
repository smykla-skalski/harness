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
use crate::commands::{self, CommandContext};
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

fn dispatch_setup(cmd: Command) -> Result<i32, CliError> {
    match cmd {
        Command::Init(args) => commands::run::init_run(
            &args.suite,
            &args.run_id,
            &args.profile,
            args.repo_root.as_deref(),
            args.run_root.as_deref(),
        ),
        Command::Bootstrap(args) => {
            commands::setup::bootstrap(args.project_dir.as_deref(), args.agent)
        }
        Command::Cluster(args) => commands::setup::cluster(&args),
        Command::Gateway(args) => commands::setup::gateway(
            args.kubeconfig.as_deref(),
            args.repo_root.as_deref(),
            args.check_only,
        ),
        Command::SessionStart(args) => commands::setup::session_start(args.project_dir.as_deref()),
        Command::SessionStop(args) => commands::setup::session_stop(args.project_dir.as_deref()),
        Command::PreCompact(args) => commands::setup::pre_compact(args.project_dir.as_deref()),
        Command::Capabilities => commands::setup::capabilities(),
        Command::Observe(args) => commands::observe::execute(args.mode),
        _ => unreachable!(),
    }
}

fn dispatch_run(ctx: &CommandContext, cmd: Command) -> Result<i32, CliError> {
    match cmd {
        Command::Capture(args) => {
            commands::run::capture(args.kubeconfig.as_deref(), &args.label, &args.run_dir)
        }
        Command::Record(args) => commands::run::record(
            args.repo_root.as_deref(),
            args.phase.as_deref(),
            args.label.as_deref(),
            args.gid.as_deref(),
            args.cluster.as_deref(),
            &args.command,
            &args.run_dir,
        ),
        Command::Apply(args) => commands::run::apply(
            args.kubeconfig.as_deref(),
            args.cluster.as_deref(),
            &args.manifest,
            args.step.as_deref(),
            &args.run_dir,
        ),
        Command::Validate(args) => commands::run::validate(
            args.kubeconfig.as_deref(),
            &args.manifest,
            args.output.as_deref(),
        ),
        Command::Preflight(args) => commands::run::preflight(
            ctx,
            args.kubeconfig.as_deref(),
            args.repo_root.as_deref(),
            &args.run_dir,
        ),
        Command::RunnerState(args) => commands::run::runner_state(
            args.event,
            args.suite_target.as_deref(),
            args.message.as_deref(),
            &args.run_dir,
        ),
        Command::Closeout(args) => commands::run::closeout(&args.run_dir),
        Command::Report(args) => commands::run::report(&args.cmd),
        Command::Diff(args) => commands::run::diff(&args.left, &args.right, args.path.as_deref()),
        Command::Envoy(args) => commands::run::envoy(&args.cmd),
        Command::Kumactl(args) => commands::run::kumactl(&args.cmd),
        Command::Api(args) => commands::run::api(&args.method),
        Command::Token(args) => commands::run::token(
            &args.kind,
            &args.name,
            &args.mesh,
            args.cp_addr.as_deref(),
            &args.valid_for,
            &args.run_dir,
        ),
        Command::Service(args) => commands::run::service(ctx, &args),
        Command::Status(args) => commands::run::status(&args.run_dir),
        Command::Logs(args) => {
            commands::run::logs(ctx, &args.name, args.tail, args.follow, &args.run_dir)
        }
        Command::ClusterCheck(args) => commands::run::cluster_check(&args.run_dir),
        Command::Task(args) => commands::run::task(&args.command),
        Command::RestartNamespace(args) => commands::run::restart_namespace(&args),
        _ => unreachable!(),
    }
}

fn dispatch_authoring(cmd: Command) -> Result<i32, CliError> {
    match cmd {
        Command::AuthoringBegin(args) => commands::authoring::begin(
            &args.repo_root,
            &args.feature,
            &args.mode,
            &args.suite_dir,
            &args.suite_name,
        ),
        Command::AuthoringSave(args) => {
            commands::authoring::save(&args.kind, args.payload.as_deref(), args.input.as_deref())
        }
        Command::AuthoringShow(args) => commands::authoring::show(&args.kind),
        Command::AuthoringReset(_args) => commands::authoring::reset(),
        Command::AuthoringValidate(args) => {
            commands::authoring::validate(&args.path, args.repo_root.as_deref())
        }
        Command::ApprovalBegin(args) => {
            commands::authoring::approval_begin(&args.mode, args.suite_dir.as_deref())
        }
        _ => unreachable!(),
    }
}

/// Dispatch a parsed command to its owning subsystem.
///
/// # Errors
/// Returns `CliError` when the selected command fails.
pub fn dispatch(command: Command) -> Result<i32, CliError> {
    match command {
        Command::Hook(_) => unreachable!("hooks are handled separately"),
        Command::Init(_)
        | Command::Bootstrap(_)
        | Command::Cluster(_)
        | Command::Gateway(_)
        | Command::SessionStart(_)
        | Command::SessionStop(_)
        | Command::PreCompact(_)
        | Command::Capabilities
        | Command::Observe(_) => dispatch_setup(command),
        Command::Capture(_)
        | Command::Record(_)
        | Command::Apply(_)
        | Command::Validate(_)
        | Command::Preflight(_)
        | Command::RunnerState(_)
        | Command::Closeout(_)
        | Command::Report(_)
        | Command::Diff(_)
        | Command::Envoy(_)
        | Command::Kumactl(_)
        | Command::Api(_)
        | Command::Token(_)
        | Command::Service(_)
        | Command::Status(_)
        | Command::Logs(_)
        | Command::ClusterCheck(_)
        | Command::Task(_)
        | Command::RestartNamespace(_) => {
            let ctx = CommandContext::production();
            dispatch_run(&ctx, command)
        }
        Command::AuthoringBegin(_)
        | Command::AuthoringSave(_)
        | Command::AuthoringShow(_)
        | Command::AuthoringReset(_)
        | Command::AuthoringValidate(_)
        | Command::ApprovalBegin(_) => dispatch_authoring(command),
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
        Command::Hook(args) => Ok(hooks::run_hook_command(args.agent, &args.skill, &args.hook)),
        other => dispatch(other),
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
