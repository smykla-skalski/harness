use super::*;
use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::Decision;
use crate::hooks::protocol::payloads::HookEnvelopePayload;

fn inactive_context() -> HookContext {
    let mut context = HookContext::from_test_envelope("", HookEnvelopePayload::default());
    context.skill_active = false;
    context
}

#[test]
fn inactive_skill_allows() {
    let ctx = inactive_context();
    let result = execute(&ctx).unwrap();
    assert_eq!(result.decision, Decision::Allow);
}
