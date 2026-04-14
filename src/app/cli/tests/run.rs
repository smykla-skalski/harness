use super::*;

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
