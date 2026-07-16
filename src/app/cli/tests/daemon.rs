use super::*;

fn rendered(args: Vec<std::ffi::OsString>) -> Vec<String> {
    args.into_iter()
        .map(|arg| arg.to_string_lossy().into_owned())
        .collect()
}

#[test]
fn parse_daemon_stop_arguments_for_worker() {
    for (argv, expected) in [
        (vec!["harness", "daemon", "stop"], Vec::<&str>::new()),
        (vec!["harness", "daemon", "stop", "--json"], vec!["--json"]),
    ] {
        let cli = Cli::try_parse_from(argv).unwrap();
        match cli.command {
            Command::Daemon {
                command: DaemonRoute::Stop(args),
            } => assert_eq!(rendered(args.args), expected),
            _ => panic!("expected daemon stop route"),
        }
    }
}

#[test]
fn parse_bridge_control_arguments_for_worker() {
    let cli = Cli::try_parse_from([
        "harness",
        "bridge",
        "reconfigure",
        "--enable",
        "codex",
        "--force",
    ])
    .unwrap();
    match cli.command {
        Command::Bridge {
            command: BridgeRoute::Reconfigure(args),
        } => assert_eq!(rendered(args.args), ["--enable", "codex", "--force"]),
        _ => panic!("expected bridge reconfigure route"),
    }
}

#[test]
fn worker_leaf_help_is_delegated() {
    for argv in [
        vec!["harness", "daemon", "stop", "--help"],
        vec!["harness", "bridge", "reconfigure", "--help"],
    ] {
        let cli = Cli::try_parse_from(argv).expect("worker should own leaf help");
        let args = match cli.command {
            Command::Daemon {
                command: DaemonRoute::Stop(args),
            }
            | Command::Bridge {
                command: BridgeRoute::Reconfigure(args),
            } => args,
            _ => panic!("expected delegated worker route"),
        };
        assert_eq!(rendered(args.args), ["--help"]);
    }
}

#[test]
fn runtime_worker_routes_are_rejected_by_root_cli() {
    for argv in [
        vec!["harness", "daemon", "serve"],
        vec!["harness", "daemon", "dev"],
        vec!["harness", "daemon", "remote", "doctor"],
        vec!["harness", "bridge", "start"],
    ] {
        let error =
            Cli::try_parse_from(argv).expect_err("runtime route must use its worker binary");
        assert_eq!(error.kind(), ErrorKind::InvalidSubcommand);
    }
}

#[test]
fn removed_agent_lifecycle_route_is_rejected() {
    let error = Cli::try_parse_from(["harness", "agents", "prompt-submit", "--agent", "codex"])
        .expect_err("legacy lifecycle route must be a hard cut");
    assert_eq!(error.kind(), ErrorKind::InvalidSubcommand);
}
