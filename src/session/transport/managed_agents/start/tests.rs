use super::*;
use clap::Parser;

/// Local harness for parsing just the managed-agents subcommand args from
/// a raw argv vec so the tests do not depend on the full CLI graph.
#[derive(clap::Parser, Debug)]
#[command(name = "terminal")]
struct TerminalParse {
    #[command(flatten)]
    args: TerminalAgentStartArgs,
}

#[derive(clap::Parser, Debug)]
#[command(name = "codex")]
struct CodexParse {
    #[command(flatten)]
    args: CodexAgentStartArgs,
}

#[derive(clap::Parser, Debug)]
#[command(name = "acp")]
struct AcpParse {
    #[command(flatten)]
    args: AcpAgentStartArgs,
}

#[derive(clap::Parser, Debug)]
#[command(name = "inspect")]
struct AcpInspectParse {
    #[command(flatten)]
    args: AcpInspectArgs,
}

#[test]
fn terminal_cli_parses_effort_and_model_at_lowest_tier() {
    // E2E intent: cheapest/fastest codex model + lowest effort level so
    // live runs stay under budget.
    let parsed = TerminalParse::try_parse_from([
        "terminal",
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
        "--runtime",
        "codex",
        "--model",
        "gpt-5.3-codex-spark",
        "--effort",
        "low",
    ])
    .expect("parse");
    assert_eq!(parsed.args.model.as_deref(), Some("gpt-5.3-codex-spark"));
    assert_eq!(parsed.args.effort.as_deref(), Some("low"));
    assert!(!parsed.args.allow_custom_model);
}

#[test]
fn terminal_cli_accepts_allow_custom_model_flag() {
    let parsed = TerminalParse::try_parse_from([
        "terminal",
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
        "--runtime",
        "claude",
        "--model",
        "claude-sonnet-5-0-private",
        "--allow-custom-model",
    ])
    .expect("parse");
    assert!(parsed.args.allow_custom_model);
    assert_eq!(
        parsed.args.model.as_deref(),
        Some("claude-sonnet-5-0-private")
    );
}

#[test]
fn acp_start_cli_parses_agent_and_session_flags() {
    let parsed = AcpParse::try_parse_from([
        "acp",
        "--agent",
        "copilot",
        "--session-id",
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
        "--prompt",
        "hello",
        "--model",
        "gpt-5.4",
        "--effort",
        "high",
        "--allow-custom-model",
        "--record-permissions",
    ])
    .expect("parse");
    assert_eq!(parsed.args.agent, "copilot");
    assert_eq!(
        parsed.args.session_id,
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc"
    );
    assert_eq!(parsed.args.prompt.as_deref(), Some("hello"));
    assert_eq!(parsed.args.model.as_deref(), Some("gpt-5.4"));
    assert_eq!(parsed.args.effort.as_deref(), Some("high"));
    assert!(parsed.args.allow_custom_model);
    assert!(parsed.args.record_permissions);
}

#[test]
fn acp_inspect_cli_accepts_optional_session_filter() {
    let parsed = AcpInspectParse::try_parse_from([
        "inspect",
        "--session-id",
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
    ])
    .expect("parse");
    assert_eq!(
        parsed.args.session_id.as_deref(),
        Some("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")
    );
    let parsed = AcpInspectParse::try_parse_from(["inspect"]).expect("parse");
    assert_eq!(parsed.args.session_id, None);
}

#[test]
fn codex_cli_parses_effort_and_model_at_lowest_tier() {
    let parsed = CodexParse::try_parse_from([
        "codex",
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
        "--prompt",
        "explore the suite",
        "--model",
        "gpt-5.3-codex-spark",
        "--effort",
        "low",
    ])
    .expect("parse");
    assert_eq!(parsed.args.model.as_deref(), Some("gpt-5.3-codex-spark"));
    assert_eq!(parsed.args.effort.as_deref(), Some("low"));
    assert!(!parsed.args.allow_custom_model);
}

#[test]
fn acp_start_cli_parses_endpoint_and_header_env() {
    let parsed = AcpParse::try_parse_from([
        "acp",
        "--agent",
        "copilot",
        "--session-id",
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
        "--endpoint",
        "https://acp.example.test",
        "--header-env",
        "Authorization=REMOTE_ACP_TOKEN",
        "--header-env",
        "X-Trace=TRACE_ID",
    ])
    .expect("parse");
    assert_eq!(
        parsed.args.endpoint.as_deref(),
        Some("https://acp.example.test")
    );
    assert_eq!(
        parsed.args.header_env,
        vec![
            "Authorization=REMOTE_ACP_TOKEN".to_string(),
            "X-Trace=TRACE_ID".to_string()
        ]
    );
}

#[test]
fn acp_start_cli_rejects_header_env_without_endpoint() {
    let error = AcpParse::try_parse_from([
        "acp",
        "--agent",
        "copilot",
        "--session-id",
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
        "--header-env",
        "Authorization=REMOTE_ACP_TOKEN",
    ])
    .expect_err("header-env requires endpoint");
    assert!(error.to_string().contains("endpoint"));
}

#[test]
fn build_endpoint_maps_header_names_to_env_vars() {
    let endpoint = build_endpoint(
        "https://acp.example.test",
        &["Authorization=REMOTE_ACP_TOKEN".to_string()],
    )
    .expect("build endpoint");
    assert_eq!(endpoint.url, "https://acp.example.test");
    assert_eq!(
        endpoint.headers_env.get("Authorization").map(String::as_str),
        Some("REMOTE_ACP_TOKEN"),
        "the map records the env var name, not the token"
    );
}

#[test]
fn build_endpoint_rejects_malformed_header_env() {
    let error =
        build_endpoint("wss://acp.example.test", &["nope".to_string()]).expect_err("malformed");
    assert!(error.to_string().contains("NAME=ENV_VAR"));
}

#[test]
fn build_endpoint_rejects_duplicate_header_names() {
    let error = build_endpoint(
        "https://acp.example.test",
        &[
            "Authorization=TOKEN_A".to_string(),
            "authorization=TOKEN_B".to_string(),
        ],
    )
    .expect_err("duplicate header name");
    assert!(error.to_string().contains("more than once"));
}
