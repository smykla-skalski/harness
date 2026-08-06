use harness_protocol::daemon::summaries::AgentWorkspaceTeamConflict;

use super::model::{MemberKey, malformed_conflict, managed_kind, role};
use super::source::RegistrationRow;

pub(super) fn registration_key(
    row: &RegistrationRow,
) -> Result<MemberKey, AgentWorkspaceTeamConflict> {
    role(&row.role).map_err(|error| source_conflict(row, error))?;
    match (&row.managed_agent_kind, &row.managed_agent_id) {
        (Some(kind), Some(id)) if !kind.is_empty() && !id.is_empty() => {
            managed_kind(kind).map_err(|error| source_conflict(row, error))?;
            Ok(MemberKey::Managed {
                kind: kind.clone(),
                id: id.clone(),
            })
        }
        (Some(_), Some(id)) if id.is_empty() => Ok(MemberKey::Legacy {
            session_id: row.session_id.clone(),
            agent_id: row.agent_id.clone(),
        }),
        (None, None) => Ok(MemberKey::Legacy {
            session_id: row.session_id.clone(),
            agent_id: row.agent_id.clone(),
        }),
        _ => Err(source_conflict(
            row,
            "managed agent kind and identifier must be present together",
        )),
    }
}

fn source_conflict(
    row: &RegistrationRow,
    detail: impl std::fmt::Display,
) -> AgentWorkspaceTeamConflict {
    malformed_conflict(
        vec![row.session_id.clone()],
        format!("agent '{}': {detail}", row.agent_id),
    )
}
