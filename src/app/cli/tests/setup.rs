use super::*;

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
fn parse_bootstrap_skip_runtime_hooks_csv() {
    let cli = Cli::try_parse_from([
        "harness",
        "setup",
        "bootstrap",
        "--skip-runtime-hooks",
        "gemini,copilot",
    ])
    .unwrap();
    let Command::Setup {
        command: SetupCommand::Bootstrap(args),
    } = cli.command
    else {
        panic!("expected bootstrap command");
    };
    assert_eq!(
        args.skip_runtime_hooks,
        vec![HookAgent::Gemini, HookAgent::Copilot]
    );
}

#[test]
fn parse_bootstrap_rejects_enable_suite_hooks_flag() {
    assert!(
        Cli::try_parse_from(["harness", "setup", "bootstrap", "--enable-suite-hooks"]).is_err()
    );
}

#[test]
fn parse_bootstrap_rejects_include_gemini_commands_flag() {
    assert!(
        Cli::try_parse_from(["harness", "setup", "bootstrap", "--include-gemini-commands"])
            .is_err()
    );
}

#[test]
fn parse_setup_rejects_removed_agents_generate_subcommand() {
    assert!(
        Cli::try_parse_from([
            "harness",
            "setup",
            "agents",
            "generate",
            "--skip-runtime-hooks",
            "gemini,copilot",
        ])
        .is_err()
    );
}

#[test]
fn parse_setup_capabilities_with_scope_overrides() {
    let cli = Cli::try_parse_from([
        "harness",
        "setup",
        "capabilities",
        "--project-dir",
        "/tmp/project",
    ])
    .unwrap();
    match cli.command {
        Command::Setup {
            command: SetupCommand::Capabilities(CapabilitiesArgs { project_dir }),
        } => {
            assert_eq!(project_dir.as_deref(), Some("/tmp/project"));
        }
        _ => panic!("expected Capabilities command"),
    }
}
