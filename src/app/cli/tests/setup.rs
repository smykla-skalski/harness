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
fn parse_bootstrap_enable_suite_hooks_flag() {
    let cli =
        Cli::try_parse_from(["harness", "setup", "bootstrap", "--enable-suite-hooks"]).unwrap();
    let Command::Setup {
        command: SetupCommand::Bootstrap(args),
    } = cli.command
    else {
        panic!("expected bootstrap command");
    };
    assert!(args.enable_suite_hooks);
    assert!(!args.enable_repo_policy);
}

#[test]
fn parse_bootstrap_enable_repo_policy_flag() {
    let cli =
        Cli::try_parse_from(["harness", "setup", "bootstrap", "--enable-repo-policy"]).unwrap();
    let Command::Setup {
        command: SetupCommand::Bootstrap(args),
    } = cli.command
    else {
        panic!("expected bootstrap command");
    };
    assert!(args.enable_repo_policy);
    assert!(!args.enable_suite_hooks);
}

#[test]
fn parse_agents_generate_enable_flags() {
    let cli = Cli::try_parse_from([
        "harness",
        "setup",
        "agents",
        "generate",
        "--enable-suite-hooks",
        "--enable-repo-policy",
    ])
    .unwrap();
    let Command::Setup {
        command:
            SetupCommand::Agents {
                command: AgentsSetupCommand::Generate(args),
            },
    } = cli.command
    else {
        panic!("expected agents generate command");
    };
    assert!(args.enable_suite_hooks);
    assert!(args.enable_repo_policy);
}

#[test]
fn parse_bootstrap_include_gemini_commands_flag() {
    let cli = Cli::try_parse_from(["harness", "setup", "bootstrap", "--include-gemini-commands"])
        .unwrap();
    let Command::Setup {
        command: SetupCommand::Bootstrap(args),
    } = cli.command
    else {
        panic!("expected bootstrap command");
    };
    assert!(args.include_gemini_commands);
}

#[test]
fn parse_agents_generate_skip_runtime_hooks_csv() {
    let cli = Cli::try_parse_from([
        "harness",
        "setup",
        "agents",
        "generate",
        "--skip-runtime-hooks",
        "gemini,copilot",
    ])
    .unwrap();
    let Command::Setup {
        command:
            SetupCommand::Agents {
                command: AgentsSetupCommand::Generate(args),
            },
    } = cli.command
    else {
        panic!("expected agents generate command");
    };
    assert_eq!(
        args.skip_runtime_hooks,
        vec![HookAgent::Gemini, HookAgent::Copilot]
    );
}

#[test]
fn parse_agents_generate_include_gemini_commands_flag() {
    let cli = Cli::try_parse_from([
        "harness",
        "setup",
        "agents",
        "generate",
        "--include-gemini-commands",
    ])
    .unwrap();
    let Command::Setup {
        command:
            SetupCommand::Agents {
                command: AgentsSetupCommand::Generate(args),
            },
    } = cli.command
    else {
        panic!("expected agents generate command");
    };
    assert!(args.include_gemini_commands);
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
