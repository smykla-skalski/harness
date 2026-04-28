use super::*;

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
