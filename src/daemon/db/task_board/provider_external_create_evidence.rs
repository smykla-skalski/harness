use chrono::DateTime;

use super::provider_external_create_rows::{create_conflict, normalize_provider_target};
use crate::daemon::db::CliError;
use crate::task_board::{
    ExternalCreateOutcome, ExternalProvider, ExternalRef, ExternalRefSyncState,
    TaskBoardExternalCreateIntent, TaskBoardStatus, normalize_repository_slug,
};

pub(super) fn validate_create_evidence(
    intent: &TaskBoardExternalCreateIntent,
    outcome: &ExternalCreateOutcome,
    provider_baseline: &ExternalRef,
) -> Result<(), CliError> {
    let reference = &outcome.reference;
    let state = provider_baseline
        .sync_state
        .as_ref()
        .ok_or_else(|| create_conflict(intent, "provider baseline has no sync state"))?;
    let target = normalized_evidence_target(intent, outcome)?;
    let outcome_project =
        normalized_optional_project(intent, outcome.provider_project_id.as_deref())?;
    let baseline_project = normalized_optional_project(intent, state.project_id.as_deref())?;
    require_matching_revision(intent, outcome, state)?;
    let matches = reference.provider == intent.provider
        && provider_baseline.provider == intent.provider.into()
        && provider_baseline.external_id == reference.external_id
        && provider_baseline.url == reference.url
        && outcome_project == baseline_project
        && optional_project_matches_identity(
            intent.provider,
            outcome_project.as_deref(),
            target.as_deref(),
        )
        && complete_provider_state(state)
        && valid_synced_at(state);
    if matches {
        Ok(())
    } else {
        Err(create_conflict(
            intent,
            "create outcome and provider baseline are inconsistent",
        ))
    }
}

pub(super) fn normalized_evidence_target(
    intent: &TaskBoardExternalCreateIntent,
    outcome: &ExternalCreateOutcome,
) -> Result<Option<String>, CliError> {
    match intent.provider {
        ExternalProvider::GitHub => {
            normalized_github_repository(intent, &outcome.reference.external_id).map(Some)
        }
        ExternalProvider::Todoist => {
            if outcome.reference.external_id.trim().is_empty() {
                return Err(create_conflict(
                    intent,
                    "Todoist create outcome has no external identity",
                ));
            }
            normalized_optional_project(intent, outcome.provider_project_id.as_deref())
        }
    }
}

fn normalized_optional_project(
    intent: &TaskBoardExternalCreateIntent,
    project: Option<&str>,
) -> Result<Option<String>, CliError> {
    project
        .map(|target| normalize_provider_target(intent.provider, target))
        .transpose()
}

fn require_matching_revision(
    intent: &TaskBoardExternalCreateIntent,
    outcome: &ExternalCreateOutcome,
    state: &ExternalRefSyncState,
) -> Result<(), CliError> {
    match (
        outcome.provider_revision.as_deref(),
        state.updated_at.as_deref(),
    ) {
        (None, None) => Ok(()),
        (Some(outcome), Some(baseline)) if !outcome.trim().is_empty() && outcome == baseline => {
            Ok(())
        }
        _ => Err(create_conflict(
            intent,
            "provider baseline revision differs from the outcome",
        )),
    }
}

fn complete_provider_state(state: &ExternalRefSyncState) -> bool {
    state.title.is_some()
        && state.body.is_some()
        && matches!(
            state.status,
            Some(TaskBoardStatus::Backlog | TaskBoardStatus::Done)
        )
}

fn valid_synced_at(state: &ExternalRefSyncState) -> bool {
    state
        .synced_at
        .as_deref()
        .is_some_and(|synced_at| DateTime::parse_from_rfc3339(synced_at).is_ok())
}

fn normalized_github_repository(
    intent: &TaskBoardExternalCreateIntent,
    external_id: &str,
) -> Result<String, CliError> {
    let Some((repository, issue)) = external_id.rsplit_once('#') else {
        return Err(create_conflict(
            intent,
            "GitHub create outcome has an invalid external identity",
        ));
    };
    if issue.is_empty() {
        return Err(create_conflict(
            intent,
            "GitHub create outcome has an invalid external identity",
        ));
    }
    normalize_repository_slug(Some(repository)).ok_or_else(|| {
        create_conflict(
            intent,
            "GitHub create outcome has an invalid external identity",
        )
    })
}

fn optional_project_matches_identity(
    provider: ExternalProvider,
    project: Option<&str>,
    target: Option<&str>,
) -> bool {
    provider != ExternalProvider::GitHub || project.is_none_or(|project| Some(project) == target)
}
