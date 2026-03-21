use super::*;

fn head() -> &'static str {
    runner_rules::PREFLIGHT_REPLY_HEAD
}

#[test]
fn parse_preflight_reply_pass() {
    let msg = format!(
        "{} pass\nPrepared suite: path/to/suite\nState capture: path/to/state\nWarnings: none",
        head()
    );
    let parsed = parse_preflight_reply(&msg).unwrap();
    assert_eq!(parsed.status, PreflightReply::Pass);
}

#[test]
fn parse_preflight_reply_fail() {
    let msg = format!("{} fail\nBlocker: cluster unreachable", head());
    let parsed = parse_preflight_reply(&msg).unwrap();
    assert_eq!(parsed.status, PreflightReply::Fail);
}

#[test]
fn parse_preflight_reply_rejects_empty() {
    let err = parse_preflight_reply("").unwrap_err();
    assert!(err.contains("preflight summary"), "got: {err}");
}

#[test]
fn parse_preflight_reply_rejects_garbage() {
    let err = parse_preflight_reply("hello world").unwrap_err();
    assert!(err.contains("first line must be"), "got: {err}");
}

#[test]
fn parse_preflight_reply_pass_requires_fields() {
    let msg = format!("{} pass", head());
    let err = parse_preflight_reply(&msg).unwrap_err();
    assert!(err.contains("Prepared suite"), "got: {err}");
}
