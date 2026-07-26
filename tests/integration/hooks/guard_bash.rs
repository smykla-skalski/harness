// Tests for the guard-bash hook.
// Verifies denial of direct cluster binary usage (kubectl, kumactl, helm,
// docker, k3d), inline python, admin endpoint access, and suite storage
// mutation on the suite:create surface, plus the inertness of the retired
// suite:run skill.

use harness::hooks::guard_bash;
use harness::hooks::hook_result::HookResult;

use super::super::helpers::*;

const GUARD_BASH_PAYLOAD_CASES: &[(&str, bool)] = &[
    ("kubectl get pods", false),
    ("harness create show --kind session", true),
    ("curl localhost:9901/config_dump", false),
    ("helm install kuma kuma/kuma", false),
    ("docker ps", false),
    ("k3d cluster list", false),
    ("echo $(kubectl get pods)", false),
    ("echo '{}' | python3 -c 'import json'", false),
    ("rm -rf ~/.local/share/harness/suites/motb", false),
    ("", true),
    ("echo hello", true),
];

fn execute_create_case(command: &str) -> HookResult {
    // session_confirms_skill sets skill_active=false when no create workflow
    // state exists. Force it true so these cases exercise guard logic rather
    // than session isolation.
    let mut ctx = make_hook_context("suite:create", make_bash_payload(command));
    ctx.skill_active = true;
    guard_bash::execute(&ctx).unwrap()
}

#[test]
fn guard_bash_payloads() {
    for &(command, should_allow) in GUARD_BASH_PAYLOAD_CASES {
        let r = execute_create_case(command);
        if should_allow {
            assert_allow(&r);
        } else {
            assert_deny(&r);
        }
    }
}

#[test]
fn guard_bash_ignores_inactive_skill() {
    let mut ctx = make_hook_context("suite:create", make_bash_payload("kubectl get pods"));
    ctx.skill_active = false;
    let r = guard_bash::execute(&ctx).unwrap();
    assert_allow(&r);
}

/// Installed hook registrations still pass `--skill suite:run`. The retired
/// runner surface must stay inert even if the session is marked active, rather
/// than falling through to the create guards.
#[test]
fn guard_bash_ignores_retired_runner_skill() {
    for command in [
        "kubectl get pods",
        "curl localhost:9901/config_dump",
        "python3 -c 'print(1)'",
    ] {
        let mut ctx = make_hook_context("suite:run", make_bash_payload(command));
        ctx.skill_active = true;
        let r = guard_bash::execute(&ctx).unwrap();
        assert_allow(&r);
    }
}

/// An active create session whose payload carries no command clears the skill
/// gate and then allows where the command is parsed, before any guard runs, so
/// a payload the hook cannot inspect is never denied.
#[test]
fn guard_bash_allows_payload_without_a_command() {
    let mut ctx = make_hook_context("suite:create", make_empty_payload());
    ctx.skill_active = true;
    let r = guard_bash::execute(&ctx).unwrap();
    assert_allow(&r);
}
