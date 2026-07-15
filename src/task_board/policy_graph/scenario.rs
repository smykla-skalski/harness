//! Workspace-scoped policy scenarios: named `PolicyInput`s the confidence panel
//! simulates against. Replaces the formerly hardcoded `simulation_inputs()` with
//! an editable, persisted set seeded from the same canonical 13 actions, so a
//! user can ask "what does my draft decide for this case" instead of only the
//! built-in baseline.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::policy::{PolicyAction, PolicyInput};

use super::PolicyCanvasWorkspace;
use super::store_canvas::simulation_inputs;

/// A named simulation case. `seeded` marks the built-in baseline scenarios so the
/// UI can distinguish them and `reset` can restore them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyScenario {
    pub id: String,
    pub name: String,
    pub input: PolicyInput,
    #[serde(default)]
    pub seeded: bool,
}

/// The default scenario set: one per canonical policy action, matching the
/// inputs the pipeline simulated before scenarios became editable.
#[must_use]
pub fn default_seeded_scenarios() -> Vec<PolicyScenario> {
    simulation_inputs()
        .into_iter()
        .map(|input| {
            let slug = action_slug(input.action);
            PolicyScenario {
                id: format!("scenario-seed-{slug}"),
                name: slug.replace('_', " "),
                input,
                seeded: true,
            }
        })
        .collect()
}

/// Append a new user scenario. `name` is trimmed and must be non-empty.
///
/// # Errors
/// Returns `CliError` when `name` is blank.
pub fn apply_scenario_create(
    ws: &mut PolicyCanvasWorkspace,
    name: &str,
    input: PolicyInput,
) -> Result<PolicyScenario, CliError> {
    let name = sanitize_scenario_name(name)?;
    let scenario = PolicyScenario {
        id: format!("scenario-{}", Uuid::new_v4().simple()),
        name,
        input,
        seeded: false,
    };
    ws.scenarios.push(scenario.clone());
    Ok(scenario)
}

/// Replace a scenario's name and input in place, preserving its id and seeded
/// origin flag.
///
/// # Errors
/// Returns `CliError` when `name` is blank or the id is unknown.
pub fn apply_scenario_update(
    ws: &mut PolicyCanvasWorkspace,
    id: &str,
    name: &str,
    input: PolicyInput,
) -> Result<PolicyScenario, CliError> {
    let name = sanitize_scenario_name(name)?;
    let scenario = ws
        .scenarios
        .iter_mut()
        .find(|scenario| scenario.id == id)
        .ok_or_else(|| unknown_scenario(id))?;
    scenario.name = name;
    scenario.input = input;
    Ok(scenario.clone())
}

/// Delete a scenario by id.
///
/// # Errors
/// Returns `CliError` when the id is unknown.
pub fn apply_scenario_delete(ws: &mut PolicyCanvasWorkspace, id: &str) -> Result<(), CliError> {
    let before = ws.scenarios.len();
    ws.scenarios.retain(|scenario| scenario.id != id);
    if ws.scenarios.len() == before {
        return Err(unknown_scenario(id));
    }
    Ok(())
}

/// Restore the default seeded scenario set, discarding user edits and additions.
pub fn apply_scenario_reset(ws: &mut PolicyCanvasWorkspace) -> Vec<PolicyScenario> {
    ws.scenarios = default_seeded_scenarios();
    ws.scenarios_seeded = true;
    ws.scenarios.clone()
}

fn action_slug(action: PolicyAction) -> String {
    serde_json::to_value(action)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_default()
}

fn sanitize_scenario_name(name: &str) -> Result<String, CliError> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err(CliErrorKind::invalid_transition(
            "policy scenario name must not be empty".to_string(),
        )
        .into());
    }
    Ok(trimmed.to_string())
}

fn unknown_scenario(id: &str) -> CliError {
    CliErrorKind::invalid_transition(format!("unknown policy scenario '{id}'")).into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::policy::{PolicyEvidence, PolicySubject};

    fn input(action: PolicyAction) -> PolicyInput {
        PolicyInput {
            workflow: None,
            action,
            subject: PolicySubject::default(),
            evidence: PolicyEvidence::default(),
            evaluated_at: None,
            approvals: Vec::new(),
        }
    }

    #[test]
    fn default_seed_covers_every_action_and_is_marked_seeded() {
        let scenarios = default_seeded_scenarios();
        assert_eq!(scenarios.len(), simulation_inputs().len());
        assert!(scenarios.iter().all(|scenario| scenario.seeded));
        assert!(
            scenarios
                .iter()
                .any(|scenario| scenario.id == "scenario-seed-merge_pr"
                    && scenario.name == "merge pr")
        );
    }

    #[test]
    fn create_appends_a_user_scenario() {
        let mut ws = PolicyCanvasWorkspace::seeded();
        let baseline = ws.scenarios.len();
        let created = apply_scenario_create(&mut ws, "  Hot merge  ", input(PolicyAction::MergePr))
            .expect("create");
        assert_eq!(created.name, "Hot merge");
        assert!(!created.seeded);
        assert_eq!(ws.scenarios.len(), baseline + 1);
    }

    #[test]
    fn create_rejects_blank_name() {
        let mut ws = PolicyCanvasWorkspace::seeded();
        assert!(apply_scenario_create(&mut ws, "   ", input(PolicyAction::Sync)).is_err());
    }

    #[test]
    fn update_replaces_name_and_input_for_known_id() {
        let mut ws = PolicyCanvasWorkspace::seeded();
        let id = ws.scenarios[0].id.clone();
        let updated =
            apply_scenario_update(&mut ws, &id, "Renamed", input(PolicyAction::DestructiveFs))
                .expect("update");
        assert_eq!(updated.name, "Renamed");
        assert_eq!(updated.input.action, PolicyAction::DestructiveFs);
    }

    #[test]
    fn delete_removes_known_id_and_errors_on_unknown() {
        let mut ws = PolicyCanvasWorkspace::seeded();
        let id = ws.scenarios[0].id.clone();
        let baseline = ws.scenarios.len();
        apply_scenario_delete(&mut ws, &id).expect("delete");
        assert_eq!(ws.scenarios.len(), baseline - 1);
        assert!(apply_scenario_delete(&mut ws, &id).is_err());
    }

    #[test]
    fn reset_restores_the_seeded_set() {
        let mut ws = PolicyCanvasWorkspace::seeded();
        ws.scenarios.clear();
        let restored = apply_scenario_reset(&mut ws);
        assert_eq!(restored, default_seeded_scenarios());
        assert!(ws.scenarios_seeded);
    }
}
