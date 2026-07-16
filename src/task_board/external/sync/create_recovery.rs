use std::mem;

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::external::{
    ExternalProviderScopeIdentity, ExternalSyncBatch, ExternalSyncClient, ExternalSyncScopeOutcome,
};
use crate::task_board::{
    ExternalProvider, ExternalSyncOperation, ExternalSyncOptions, TaskBoardExternalCreateIntent,
    TaskBoardExternalCreateIntentState,
};

use super::TaskBoardSyncStore;

mod execute;
mod lease;
pub(super) use execute::{
    create_item_durably, recover_scope_intents, suppress_known_create_markers,
};
use execute::{finalize_intent, queue_attached_follow_up};

pub(crate) struct ExternalCreateRecoveryWork {
    created: Vec<TaskBoardExternalCreateIntent>,
    in_flight: Vec<TaskBoardExternalCreateIntent>,
}

#[derive(Default)]
pub(crate) struct PreparedExternalCreateRecovery {
    operations: Vec<ExternalSyncOperation>,
    in_flight: Vec<TaskBoardExternalCreateIntent>,
    recovered: Vec<TaskBoardExternalCreateIntent>,
    follow_ups: Vec<TaskBoardExternalCreateIntent>,
}

#[derive(Default)]
pub(crate) struct ExternalCreateRecoveryPlan {
    operations: Vec<ExternalSyncOperation>,
    follow_ups: Vec<TaskBoardExternalCreateIntent>,
    scopes: Vec<OwnedRecoveryScope>,
}

struct OwnedRecoveryScope {
    provider: ExternalProvider,
    scope_id: String,
    intents: Vec<TaskBoardExternalCreateIntent>,
    recovered: Vec<TaskBoardExternalCreateIntent>,
}

#[derive(Default)]
pub(crate) struct ExternalCreateScopeRecovery {
    pub(super) intents: Vec<TaskBoardExternalCreateIntent>,
    pub(super) touched: bool,
}

pub(crate) async fn load_external_create_recovery_work(
    board: &dyn TaskBoardSyncStore,
    provider: Option<ExternalProvider>,
) -> Result<ExternalCreateRecoveryWork, CliError> {
    let created = board.list_created_external_create_intents().await?;
    let providers = requested_providers(provider);
    let mut filtered_created = Vec::new();
    let mut in_flight = Vec::new();
    for candidate in &providers {
        filtered_created.extend(
            created
                .iter()
                .filter(|intent| intent.provider == *candidate)
                .cloned(),
        );
        in_flight.extend(
            board
                .list_in_flight_external_create_intents(*candidate)
                .await?,
        );
    }
    Ok(ExternalCreateRecoveryWork {
        created: filtered_created,
        in_flight,
    })
}

pub(crate) async fn prepare_external_create_recovery(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    work: ExternalCreateRecoveryWork,
) -> Result<PreparedExternalCreateRecovery, ExternalSyncBatch> {
    if work.is_empty() {
        return Ok(PreparedExternalCreateRecovery::default());
    }
    if options.dry_run {
        let error =
            CliErrorKind::workflow_io("pending provider create recovery blocks dry-run sync")
                .into();
        return Err(blocked_batch(
            Vec::new(),
            Vec::new(),
            work.all_intents(),
            error,
        ));
    }
    let mut operations = Vec::new();
    let mut in_flight = work.in_flight;
    let mut recovered = Vec::new();
    let mut follow_ups = Vec::new();
    for listed in work.created {
        let current = match reload_intent(board, &listed).await {
            Ok(intent) => intent,
            Err(error) => {
                return Err(blocked_batch(operations, follow_ups, vec![listed], error));
            }
        };
        match current.state {
            TaskBoardExternalCreateIntentState::InFlight => in_flight.push(current),
            TaskBoardExternalCreateIntentState::Created(_) => {
                if let Err(error) =
                    finalize_intent(board, &current, &mut operations, &mut follow_ups).await
                {
                    return Err(blocked_batch(operations, follow_ups, vec![current], error));
                }
                recovered.push(current);
            }
            TaskBoardExternalCreateIntentState::Attached(_) => {
                if let Err(error) = queue_attached_follow_up(&current, &mut follow_ups) {
                    return Err(blocked_batch(operations, follow_ups, vec![current], error));
                }
            }
        }
    }
    Ok(PreparedExternalCreateRecovery {
        operations,
        in_flight,
        recovered,
        follow_ups,
    })
}

#[expect(
    clippy::result_large_err,
    reason = "the blocked batch intentionally retains complete operation and scope evidence"
)]
pub(crate) fn assign_external_create_recovery(
    prepared: PreparedExternalCreateRecovery,
    clients: &[Box<dyn ExternalSyncClient>],
) -> Result<ExternalCreateRecoveryPlan, ExternalSyncBatch> {
    let mut scopes: Vec<OwnedRecoveryScope> = Vec::new();
    for intent in &prepared.recovered {
        let scope = recovery_scope(&mut scopes, intent);
        scope.recovered.push(intent.clone());
    }
    for intent in &prepared.in_flight {
        let owners = clients
            .iter()
            .filter(|client| client_owns_intent(client.as_ref(), intent))
            .collect::<Vec<_>>();
        if owners.len() != 1 {
            let error = owner_error(intent, owners.len());
            let intents = prepared
                .in_flight
                .iter()
                .chain(&prepared.recovered)
                .cloned()
                .collect();
            return Err(blocked_batch(
                prepared.operations,
                prepared.follow_ups,
                intents,
                error,
            ));
        }
        recovery_scope(&mut scopes, intent)
            .intents
            .push(intent.clone());
    }
    Ok(ExternalCreateRecoveryPlan {
        operations: prepared.operations,
        follow_ups: prepared.follow_ups,
        scopes,
    })
}

pub(crate) fn blocked_external_create_recovery(
    prepared: PreparedExternalCreateRecovery,
    error: CliError,
) -> ExternalSyncBatch {
    let intents = prepared
        .in_flight
        .into_iter()
        .chain(prepared.recovered)
        .collect();
    blocked_batch(prepared.operations, prepared.follow_ups, intents, error)
}

pub(crate) fn blocked_external_create_follow_ups(
    intents: Vec<TaskBoardExternalCreateIntent>,
    error: CliError,
) -> ExternalSyncBatch {
    blocked_batch(Vec::new(), intents.clone(), intents, error)
}

impl ExternalCreateRecoveryWork {
    pub(crate) fn is_empty(&self) -> bool {
        self.created.is_empty() && self.in_flight.is_empty()
    }

    fn all_intents(self) -> Vec<TaskBoardExternalCreateIntent> {
        self.created.into_iter().chain(self.in_flight).collect()
    }
}

impl PreparedExternalCreateRecovery {
    pub(crate) fn is_empty(&self) -> bool {
        self.operations.is_empty()
            && self.in_flight.is_empty()
            && self.recovered.is_empty()
            && self.follow_ups.is_empty()
    }

    pub(crate) fn follow_ups(&self) -> &[TaskBoardExternalCreateIntent] {
        &self.follow_ups
    }

    pub(crate) fn clear_follow_ups(&mut self) {
        self.follow_ups.clear();
    }
}

impl ExternalCreateRecoveryPlan {
    pub(crate) fn take_operations(&mut self) -> Vec<ExternalSyncOperation> {
        mem::take(&mut self.operations)
    }

    pub(crate) fn take_follow_ups(&mut self) -> Vec<TaskBoardExternalCreateIntent> {
        mem::take(&mut self.follow_ups)
    }

    pub(crate) fn take_scope(
        &mut self,
        provider: ExternalProvider,
        scope_id: &str,
    ) -> ExternalCreateScopeRecovery {
        let Some(index) = self
            .scopes
            .iter()
            .position(|scope| scope.provider == provider && scope.scope_id == scope_id)
        else {
            return ExternalCreateScopeRecovery::default();
        };
        let scope = self.scopes.swap_remove(index);
        ExternalCreateScopeRecovery {
            intents: scope.intents,
            touched: true,
        }
    }

    pub(crate) fn has_recovery(&self) -> bool {
        !self.scopes.is_empty()
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.operations.is_empty() && self.follow_ups.is_empty() && self.scopes.is_empty()
    }

    pub(crate) fn into_blocked(self, error: CliError) -> ExternalSyncBatch {
        let intents = self
            .scopes
            .into_iter()
            .flat_map(|scope| scope.intents.into_iter().chain(scope.recovered))
            .collect();
        blocked_batch(self.operations, self.follow_ups, intents, error)
    }
}

fn recovery_scope<'a>(
    scopes: &'a mut Vec<OwnedRecoveryScope>,
    intent: &TaskBoardExternalCreateIntent,
) -> &'a mut OwnedRecoveryScope {
    if let Some(index) = scopes
        .iter()
        .position(|scope| scope.provider == intent.provider && scope.scope_id == intent.scope_id)
    {
        return &mut scopes[index];
    }
    scopes.push(OwnedRecoveryScope {
        provider: intent.provider,
        scope_id: intent.scope_id.clone(),
        intents: Vec::new(),
        recovered: Vec::new(),
    });
    scopes.last_mut().expect("recovery scope was inserted")
}

fn client_owns_intent(
    client: &dyn ExternalSyncClient,
    intent: &TaskBoardExternalCreateIntent,
) -> bool {
    client.provider() == intent.provider
        && client.allows_push()
        && ExternalProviderScopeIdentity::for_client(client).scope_id() == intent.scope_id
        && client.external_create_recovery().is_some_and(|capability| {
            capability.provider() == intent.provider
                && capability.supports_target(&intent.snapshot.provider_target)
        })
}

pub(super) async fn reload_intent(
    board: &dyn TaskBoardSyncStore,
    expected: &TaskBoardExternalCreateIntent,
) -> Result<TaskBoardExternalCreateIntent, CliError> {
    let current = board
        .external_create_intent_by_create_key(expected.provider, &expected.create_key)
        .await?
        .ok_or_else(|| {
            CliErrorKind::concurrent_modification("provider create intent disappeared")
        })?;
    if current.intent_id == expected.intent_id && current.item_id == expected.item_id {
        Ok(current)
    } else {
        Err(CliErrorKind::concurrent_modification(
            "provider create key resolved to different intent evidence",
        )
        .into())
    }
}

fn owner_error(intent: &TaskBoardExternalCreateIntent, owners: usize) -> CliError {
    if owners == 0 {
        CliErrorKind::workflow_io(format!(
            "provider create for '{}' has no configured write owner for scope '{}'",
            intent.item_id, intent.scope_id
        ))
        .into()
    } else {
        CliErrorKind::concurrent_modification(format!(
            "provider create for '{}' has {owners} configured write owners for scope '{}'",
            intent.item_id, intent.scope_id
        ))
        .into()
    }
}

fn blocked_batch(
    operations: Vec<ExternalSyncOperation>,
    follow_ups: Vec<TaskBoardExternalCreateIntent>,
    intents: Vec<TaskBoardExternalCreateIntent>,
    error: CliError,
) -> ExternalSyncBatch {
    let mut scope_outcomes = Vec::new();
    for intent in intents {
        if scope_outcomes
            .iter()
            .any(|outcome: &ExternalSyncScopeOutcome| {
                outcome.provider == intent.provider && outcome.scope_id == intent.scope_id
            })
        {
            continue;
        }
        scope_outcomes.push(ExternalSyncScopeOutcome::failed(
            intent.provider,
            intent.scope_id,
            &error,
        ));
    }
    ExternalSyncBatch {
        operations,
        external_create_follow_ups: follow_ups,
        scope_outcomes,
        first_provider_failure: None,
        terminal_error: Some(error),
    }
}

fn requested_providers(provider: Option<ExternalProvider>) -> Vec<ExternalProvider> {
    provider.map_or_else(
        || vec![ExternalProvider::GitHub, ExternalProvider::Todoist],
        |provider| vec![provider],
    )
}
