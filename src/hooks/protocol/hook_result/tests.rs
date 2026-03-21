use super::*;

#[test]
fn allow_has_empty_code_and_message() {
    let result = HookResult::allow();
    assert_eq!(result.decision, Decision::Allow);
    assert!(result.code.is_empty());
    assert!(result.message.is_empty());
}

#[test]
fn deny_has_correct_decision() {
    let result = HookResult::deny("KSR005", "bad");
    assert_eq!(result.decision, Decision::Deny);
    assert_eq!(result.code, "KSR005");
    assert_eq!(result.message, "bad");
}

#[test]
fn warn_has_correct_decision() {
    let result = HookResult::warn("KSR006", "watch out");
    assert_eq!(result.decision, Decision::Warn);
    assert_eq!(result.code, "KSR006");
    assert_eq!(result.message, "watch out");
}

#[test]
fn info_has_correct_decision() {
    let result = HookResult::info("KSR012", "verdict: pass");
    assert_eq!(result.decision, Decision::Info);
    assert_eq!(result.code, "KSR012");
    assert_eq!(result.message, "verdict: pass");
}

#[test]
fn emit_allow_returns_zero() {
    let result = HookResult::allow();
    assert_eq!(result.emit().unwrap(), 0);
}

#[test]
fn emit_deny_returns_zero() {
    let result = HookResult::deny("X", "msg");
    assert_eq!(result.emit().unwrap(), 0);
}

#[test]
fn serialize_to_json() {
    let result = HookResult::deny("KSR005", "test message");
    let json = serde_json::to_value(&result).unwrap();
    assert_eq!(json["decision"], "deny");
    assert_eq!(json["code"], "KSR005");
    assert_eq!(json["message"], "test message");
}

#[test]
fn equality() {
    let first = HookResult::deny("X", "msg");
    let second = HookResult::deny("X", "msg");
    assert_eq!(first, second);
}

#[test]
fn inequality_different_decision() {
    let first = HookResult::deny("X", "msg");
    let second = HookResult::warn("X", "msg");
    assert_ne!(first, second);
}

#[test]
fn clone_is_equal() {
    let first = HookResult::info("KSR012", "test");
    let second = first.clone();
    assert_eq!(first, second);
}
