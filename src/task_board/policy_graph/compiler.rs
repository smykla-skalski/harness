//! Domain-agnostic compilation of an authored workflow graph into an ordered
//! list of runtime steps.
//!
//! Any workflow domain (Reviews today, broader orchestration later) shares this
//! compiler: it simulates the graph for a given workflow and turns the visited
//! `ActionStep` / `WaitStep` / `EventWait` nodes into abstract steps. The domain
//! wrapper maps the abstract `action_id`s onto concrete provider actions, so the
//! graph-to-runtime seam is no longer Reviews-specific.

use super::{PolicyGraph, PolicyGraphNodeKind, PolicyWaitCondition};
use crate::task_board::policy::{PolicyDecision, PolicyInput};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CompiledWorkflowStep {
    Action { action_id: String },
    Wait(PolicyWaitCondition),
}

#[derive(Debug, Clone)]
pub struct CompiledWorkflowPlan {
    pub steps: Vec<CompiledWorkflowStep>,
    pub decision: PolicyDecision,
    /// Set when the workflow reached a node the runtime cannot execute yet
    /// (e.g. a handoff). The plan is not actionable in that case.
    pub blocked_reason: Option<String>,
}

impl PolicyGraph {
    /// Compile the workflow identified by `workflow_id` into ordered runtime
    /// steps by simulating the graph against `input`. Returns `None` when the
    /// graph defines no matching workflow entry, so callers never mistake the
    /// built-in gate fallback for an authored workflow.
    #[must_use]
    pub fn compile_workflow(
        &self,
        workflow_id: &str,
        input: &PolicyInput,
    ) -> Option<CompiledWorkflowPlan> {
        if !self.defines_workflow(workflow_id) {
            return None;
        }
        let simulation = self.simulate(input);
        let mut steps = Vec::new();
        let mut blocked_reason = None;
        for node_id in &simulation.visited_node_ids {
            let Some(node) = self.nodes.iter().find(|node| node.id == *node_id) else {
                continue;
            };
            match &node.kind {
                PolicyGraphNodeKind::ActionStep(action) => {
                    steps.push(CompiledWorkflowStep::Action {
                        action_id: action.action_id.clone(),
                    });
                }
                PolicyGraphNodeKind::WaitStep(wait) => {
                    steps.push(CompiledWorkflowStep::Wait(wait.wait.clone()));
                }
                PolicyGraphNodeKind::EventWait(wait) => {
                    steps.push(CompiledWorkflowStep::Wait(PolicyWaitCondition::Event {
                        event_key: wait.event_key.clone(),
                    }));
                }
                PolicyGraphNodeKind::Handoff(handoff) => {
                    blocked_reason = Some(format!(
                        "workflow contains an unsupported handoff '{}'",
                        handoff.handoff_key
                    ));
                    break;
                }
                _ => {}
            }
        }
        Some(CompiledWorkflowPlan {
            steps,
            decision: simulation.decision,
            blocked_reason,
        })
    }

    fn defines_workflow(&self, workflow_id: &str) -> bool {
        self.nodes.iter().any(|node| match &node.kind {
            PolicyGraphNodeKind::WorkflowEntry(entry) => {
                entry.workflow_id.eq_ignore_ascii_case(workflow_id)
            }
            PolicyGraphNodeKind::Trigger { workflow } => workflow.eq_ignore_ascii_case(workflow_id),
            _ => false,
        })
    }
}
