use crate::session::types::SessionRole;

/// Build the skill invocation string that the daemon sends as the first PTY
/// input so the agent auto-joins the session.
#[expect(
    clippy::too_many_arguments,
    reason = "auto-join prompt generation needs to thread join flags explicitly"
)]
pub(crate) fn build_auto_join_prompt(
    runtime: &str,
    session_id: &str,
    role: SessionRole,
    fallback_role: Option<SessionRole>,
    capabilities: &[String],
    tui_id: &str,
    name: Option<&str>,
    persona: Option<&str>,
) -> String {
    let mut caps: Vec<&str> = capabilities.iter().map(String::as_str).collect();
    let marker = format!("agent-tui:{tui_id}");
    for capability in ["agent-tui", marker.as_str()] {
        if !caps.contains(&capability) {
            caps.push(capability);
        }
    }
    let caps_joined = caps.join(",");

    let role_str = match role {
        SessionRole::Leader => "leader",
        SessionRole::Worker => "worker",
        SessionRole::Observer => "observer",
        SessionRole::Reviewer => "reviewer",
        SessionRole::Improver => "improver",
    };

    let name_flag = name.map_or_else(String::new, |value| format!(" --name \"{value}\""));
    let persona_flag = persona.map_or_else(String::new, |value| format!(" --persona \"{value}\""));
    let fallback_role_flag = fallback_role.map_or_else(String::new, |value| {
        let value = match value {
            SessionRole::Leader => "leader",
            SessionRole::Worker => "worker",
            SessionRole::Observer => "observer",
            SessionRole::Reviewer => "reviewer",
            SessionRole::Improver => "improver",
        };
        format!(" --fallback-role {value}")
    });
    format!(
        "harness session join {session_id} --role {role_str} --runtime {runtime} --capabilities \"{caps_joined}\"{fallback_role_flag}{name_flag}{persona_flag}"
    )
}
