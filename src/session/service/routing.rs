use crate::session::types::{AgentRegistration, WorkItem};

/// Rank worker candidates for a task.
///
/// Workers whose persona identifier matches `task.suggested_persona`
/// come first (distance 0); workers with a persona that does not match
/// come next (distance 1); workers with no persona come last (distance
/// 2). Ties break on `agent_id` so the result is deterministic.
///
/// The caller is expected to have already filtered workers for liveness
/// and assignability.
pub(crate) fn rank_workers_for_task(task: &WorkItem, workers: &[&AgentRegistration]) -> Vec<String> {
    let mut ranked: Vec<(u8, &str)> = workers
        .iter()
        .map(|agent| (persona_distance(task.suggested_persona.as_deref(), agent), agent.agent_id.as_str()))
        .collect();
    ranked.sort_unstable();
    ranked
        .into_iter()
        .map(|(_, id)| id.to_string())
        .collect()
}

fn persona_distance(suggested: Option<&str>, agent: &AgentRegistration) -> u8 {
    match (suggested, agent.persona.as_ref()) {
        (Some(slug), Some(persona)) if persona.identifier == slug => 0,
        (_, Some(_)) => 1,
        (_, None) => 2,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::types::{
        AgentPersona, AgentStatus, PersonaSymbol, SessionRole, TaskSeverity, TaskSource, TaskStatus,
        WorkItem,
    };

    fn persona(identifier: &str) -> AgentPersona {
        AgentPersona {
            identifier: identifier.to_string(),
            name: identifier.to_string(),
            symbol: PersonaSymbol::SfSymbol {
                name: "person".to_string(),
            },
            description: String::new(),
        }
    }

    fn agent(id: &str, persona_id: Option<&str>) -> AgentRegistration {
        AgentRegistration {
            agent_id: id.to_string(),
            name: id.to_string(),
            runtime: "codex".to_string(),
            role: SessionRole::Worker,
            capabilities: Vec::new(),
            joined_at: "now".to_string(),
            updated_at: "now".to_string(),
            status: AgentStatus::Active,
            agent_session_id: None,
            last_activity_at: None,
            current_task_id: None,
            runtime_capabilities: Default::default(),
            persona: persona_id.map(persona),
        }
    }

    fn task_with_persona(suggested: Option<&str>) -> WorkItem {
        WorkItem {
            task_id: "t1".to_string(),
            title: "t".to_string(),
            context: None,
            severity: TaskSeverity::Medium,
            status: TaskStatus::Open,
            assigned_to: None,
            queue_policy: Default::default(),
            queued_at: None,
            created_at: "now".to_string(),
            updated_at: "now".to_string(),
            created_by: None,
            notes: Vec::new(),
            suggested_fix: None,
            source: TaskSource::default(),
            observe_issue_id: None,
            blocked_reason: None,
            completed_at: None,
            checkpoint_summary: None,
            awaiting_review: None,
            review_claim: None,
            consensus: None,
            review_round: 0,
            arbitration: None,
            suggested_persona: suggested.map(str::to_string),
        }
    }

    #[test]
    fn matching_persona_ranks_first() {
        let task = task_with_persona(Some("test-writer"));
        let a = agent("a", Some("code-reviewer"));
        let b = agent("b", Some("test-writer"));
        let c = agent("c", None);
        let ranked = rank_workers_for_task(&task, &[&a, &b, &c]);
        assert_eq!(ranked, vec!["b", "a", "c"]);
    }

    #[test]
    fn without_suggested_persona_keeps_persona_agents_ahead_of_bare_ones() {
        let task = task_with_persona(None);
        let a = agent("a", Some("test-writer"));
        let b = agent("b", None);
        let ranked = rank_workers_for_task(&task, &[&a, &b]);
        assert_eq!(ranked, vec!["a", "b"]);
    }

    #[test]
    fn tie_breaks_on_agent_id() {
        let task = task_with_persona(Some("test-writer"));
        let a = agent("zz", Some("test-writer"));
        let b = agent("aa", Some("test-writer"));
        let ranked = rank_workers_for_task(&task, &[&a, &b]);
        assert_eq!(ranked, vec!["aa", "zz"]);
    }
}
