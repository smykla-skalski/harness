use std::future::Future;

use harness_daemon_db_core::{AsyncDaemonDb, db_error};
use harness_kernel::errors::CliError;
use harness_protocol::daemon::summaries::{
    AgentWorkspaceMemberOperationKind, AgentWorkspaceMemberOperationOutcome,
};
use harness_protocol::session::ManagedAgentKind;
use sqlx::{FromRow, Sqlite, Transaction, query, query_as};

use super::operation_rules::{apply_successful_operation, validate_membership_removal};
use super::persist::refresh_shadow_digest;

#[derive(Debug, FromRow)]
struct MemberLocation {
    workspace_id: String,
    member_id: String,
    membership_status: String,
    runtime_lifecycle: String,
    membership_source_digest: String,
    runtime_source_digest: String,
}

#[derive(Debug, FromRow)]
struct SourceWorkspace {
    daemon_id: String,
    workspace_id: String,
}

pub(super) struct ReconciledLocation {
    current: MemberLocation,
    previous: Option<MemberLocation>,
}

#[derive(Clone, Copy)]
pub(super) enum MemberLocator<'a> {
    Managed {
        daemon_id: &'a str,
        kind: ManagedAgentKind,
        id: &'a str,
    },
    Legacy {
        daemon_id: &'a str,
        session_id: &'a str,
        agent_id: &'a str,
    },
    Durable {
        daemon_id: &'a str,
        workspace_id: &'a str,
        member_id: &'a str,
    },
}

pub trait AsyncAgentWorkspaceTeamOperationQueries: Send + Sync {
    /// Record a managed runtime stop independently from team membership.
    ///
    /// # Errors
    /// Returns [`CliError`] on ambiguous identity or persistence failure.
    fn record_agent_workspace_runtime_stop(
        &self,
        daemon_id: &str,
        kind: ManagedAgentKind,
        managed_agent_id: &str,
        outcome: AgentWorkspaceMemberOperationOutcome,
        detail: Option<&str>,
    ) -> impl Future<Output = Result<bool, CliError>> + Send;

    /// Record membership removal independently from runtime lifecycle.
    ///
    /// # Errors
    /// Returns [`CliError`] on ambiguous identity or persistence failure.
    fn record_agent_workspace_membership_removal(
        &self,
        daemon_id: &str,
        session_id: &str,
        agent_id: &str,
        outcome: AgentWorkspaceMemberOperationOutcome,
        detail: Option<&str>,
    ) -> impl Future<Output = Result<bool, CliError>> + Send;

    /// Record membership removal using workspace-owned identity.
    ///
    /// # Errors
    /// Returns [`CliError`] when the workspace member cannot be reconciled or persisted.
    fn record_agent_workspace_member_removal(
        &self,
        daemon_id: &str,
        workspace_id: &str,
        member_id: &str,
        outcome: AgentWorkspaceMemberOperationOutcome,
        detail: Option<&str>,
    ) -> impl Future<Output = Result<bool, CliError>> + Send;
}

impl AsyncAgentWorkspaceTeamOperationQueries for AsyncDaemonDb {
    async fn record_agent_workspace_runtime_stop(
        &self,
        daemon_id: &str,
        kind: ManagedAgentKind,
        managed_agent_id: &str,
        outcome: AgentWorkspaceMemberOperationOutcome,
        detail: Option<&str>,
    ) -> Result<bool, CliError> {
        record_located_operation(
            self,
            MemberLocator::Managed {
                daemon_id,
                kind,
                id: managed_agent_id,
            },
            AgentWorkspaceMemberOperationKind::RuntimeStop,
            outcome,
            detail,
        )
        .await
    }

    async fn record_agent_workspace_membership_removal(
        &self,
        daemon_id: &str,
        session_id: &str,
        agent_id: &str,
        outcome: AgentWorkspaceMemberOperationOutcome,
        detail: Option<&str>,
    ) -> Result<bool, CliError> {
        record_located_operation(
            self,
            MemberLocator::Legacy {
                daemon_id,
                session_id,
                agent_id,
            },
            AgentWorkspaceMemberOperationKind::MembershipRemove,
            outcome,
            detail,
        )
        .await
    }

    async fn record_agent_workspace_member_removal(
        &self,
        daemon_id: &str,
        workspace_id: &str,
        member_id: &str,
        outcome: AgentWorkspaceMemberOperationOutcome,
        detail: Option<&str>,
    ) -> Result<bool, CliError> {
        record_located_operation(
            self,
            MemberLocator::Durable {
                daemon_id,
                workspace_id,
                member_id,
            },
            AgentWorkspaceMemberOperationKind::MembershipRemove,
            outcome,
            detail,
        )
        .await
    }
}

async fn record_located_operation(
    db: &AsyncDaemonDb,
    locator: MemberLocator<'_>,
    kind: AgentWorkspaceMemberOperationKind,
    outcome: AgentWorkspaceMemberOperationOutcome,
    detail: Option<&str>,
) -> Result<bool, CliError> {
    let mut transaction = db
        .pool()
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(|error| db_error(format!("begin durable member operation: {error}")))?;
    let location = resolve_or_reconcile_location(&mut transaction, locator).await?;
    let Some(location) = location else {
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit empty member operation: {error}")))?;
        return Ok(false);
    };
    if kind == AgentWorkspaceMemberOperationKind::MembershipRemove {
        validate_membership_removal(
            &mut transaction,
            &location.current.workspace_id,
            &location.current.member_id,
            outcome,
        )
        .await?;
    }
    let recorded_at = harness_workspace::workspace::utc_now();
    let kind_label = operation_kind_label(kind);
    let outcome_label = operation_outcome_label(outcome);
    let before_state = operation_before_state(
        location.previous.as_ref().unwrap_or(&location.current),
        kind,
    );
    let after_state = operation_after_state(kind, outcome, before_state);
    let source_marker = operation_source_marker(&location.current, kind);
    query(
        "INSERT INTO agent_workspace_member_operations (
                operation_id, workspace_id, member_id, operation_kind, outcome,
                before_state, after_state, source_marker, detail, recorded_at
             ) VALUES (
                'operation-' || lower(hex(randomblob(16))),
                ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9
             )",
    )
    .bind(&location.current.workspace_id)
    .bind(&location.current.member_id)
    .bind(kind_label)
    .bind(outcome_label)
    .bind(before_state)
    .bind(after_state)
    .bind(source_marker)
    .bind(detail)
    .bind(&recorded_at)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("record durable member operation: {error}")))?;
    apply_successful_operation(
        &mut transaction,
        &location.current.workspace_id,
        &location.current.member_id,
        kind,
        outcome,
        &recorded_at,
    )
    .await?;
    refresh_shadow_digest(&mut transaction, &location.current.workspace_id).await?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit durable member operation: {error}")))?;
    Ok(true)
}

pub(super) async fn resolve_or_reconcile_location(
    transaction: &mut Transaction<'_, Sqlite>,
    locator: MemberLocator<'_>,
) -> Result<Option<ReconciledLocation>, CliError> {
    let previous = resolve_location(transaction, locator).await?;
    let source = resolve_source_workspace(transaction, locator).await?;
    if let Some(source) = &source {
        let conflicts = super::reconcile_workspace_teams(
            transaction,
            &source.daemon_id,
            Some(&source.workspace_id),
        )
        .await?
        .remove(&source.workspace_id)
        .unwrap_or_default();
        if !conflicts.is_empty() {
            return Err(db_error(format!(
                "durable member operation source reconciliation reported {} conflict(s)",
                conflicts.len()
            )));
        }
    }
    let current = resolve_location(transaction, locator).await?;
    current.map_or_else(
        || {
            source.as_ref().map_or(Ok(None), |source| {
                Err(db_error(format!(
                    "durable member operation source in workspace '{}' did not materialize a member",
                    source.workspace_id
                )))
            })
        },
        |current| {
            if previous.as_ref().is_some_and(|previous| {
                previous.workspace_id != current.workspace_id
                    || previous.member_id != current.member_id
            }) {
                return Err(db_error(
                    "durable member identity changed during source reconciliation",
                ));
            }
            Ok(Some(ReconciledLocation { current, previous }))
        },
    )
}

async fn resolve_source_workspace(
    transaction: &mut Transaction<'_, Sqlite>,
    locator: MemberLocator<'_>,
) -> Result<Option<SourceWorkspace>, CliError> {
    let (sources, identity) = match locator {
        MemberLocator::Managed {
            daemon_id,
            kind,
            id,
        } => (
            query_as::<_, SourceWorkspace>(
                "SELECT DISTINCT workspace.daemon_id, workspace.workspace_id
                 FROM agent_workspaces workspace
                 JOIN agent_workspace_legacy_sessions link
                   ON link.workspace_id = workspace.workspace_id
                 WHERE workspace.daemon_id = ?1 AND (EXISTS (
                     SELECT 1 FROM agents registration
                     WHERE registration.session_id = link.session_id
                       AND registration.managed_agent_kind = ?2
                       AND registration.managed_agent_id = ?3
                 ) OR (?2 = 'tui' AND EXISTS (
                     SELECT 1 FROM agent_tuis runtime
                     WHERE runtime.session_id = link.session_id AND runtime.tui_id = ?3
                 )) OR (?2 = 'codex' AND EXISTS (
                     SELECT 1 FROM codex_runs runtime
                     WHERE runtime.session_id = link.session_id AND runtime.run_id = ?3
                 )))
                 ORDER BY workspace.workspace_id",
            )
            .bind(daemon_id)
            .bind(managed_kind_label(kind))
            .bind(id)
            .fetch_all(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("resolve managed operation source: {error}")))?,
            "managed runtime source",
        ),
        MemberLocator::Legacy {
            daemon_id,
            session_id,
            agent_id: _,
        } => (
            query_as::<_, SourceWorkspace>(
                "SELECT DISTINCT workspace.daemon_id, workspace.workspace_id
                 FROM agent_workspaces workspace
                 JOIN agent_workspace_legacy_sessions link
                   ON link.workspace_id = workspace.workspace_id
                 WHERE workspace.daemon_id = ?1 AND link.session_id = ?2
                 ORDER BY workspace.workspace_id",
            )
            .bind(daemon_id)
            .bind(session_id)
            .fetch_all(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("resolve membership operation source: {error}")))?,
            "legacy membership source",
        ),
        MemberLocator::Durable {
            daemon_id,
            workspace_id,
            member_id: _,
        } => (
            query_as::<_, SourceWorkspace>(
                "SELECT daemon_id, workspace_id FROM agent_workspaces
                 WHERE daemon_id = ?1 AND workspace_id = ?2",
            )
            .bind(daemon_id)
            .bind(workspace_id)
            .fetch_all(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("resolve durable membership source: {error}")))?,
            "durable membership source",
        ),
    };
    unique_source_workspace(sources, identity)
}

fn unique_source_workspace(
    mut sources: Vec<SourceWorkspace>,
    identity: &str,
) -> Result<Option<SourceWorkspace>, CliError> {
    if sources.len() > 1 {
        return Err(db_error(format!(
            "{identity} resolves to multiple durable workspaces"
        )));
    }
    Ok(sources.pop())
}

async fn resolve_location(
    transaction: &mut Transaction<'_, Sqlite>,
    locator: MemberLocator<'_>,
) -> Result<Option<MemberLocation>, CliError> {
    let (locations, identity) = match locator {
        MemberLocator::Managed {
            daemon_id,
            kind,
            id,
        } => (
            query_as::<_, MemberLocation>(
                "SELECT member.workspace_id, member.member_id, member.membership_status,
                        member.runtime_lifecycle, member.membership_source_digest,
                        member.runtime_source_digest
                 FROM agent_workspace_members member
                 JOIN agent_workspaces workspace ON workspace.workspace_id = member.workspace_id
                 WHERE workspace.daemon_id = ?1
                   AND member.managed_agent_kind = ?2 AND member.managed_agent_id = ?3
                 ORDER BY member.workspace_id",
            )
            .bind(daemon_id)
            .bind(managed_kind_label(kind))
            .bind(id)
            .fetch_all(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("resolve durable runtime member: {error}")))?,
            "managed runtime",
        ),
        MemberLocator::Legacy {
            daemon_id,
            session_id,
            agent_id,
        } => (
            query_as::<_, MemberLocation>(
                "SELECT member.workspace_id, member.member_id,
                        member.membership_status, member.runtime_lifecycle,
                        member.membership_source_digest, member.runtime_source_digest
                 FROM agent_workspace_member_provenance provenance
                 JOIN agent_workspace_members member
                   ON member.workspace_id = provenance.workspace_id
                  AND member.member_id = provenance.member_id
                 JOIN agent_workspaces workspace ON workspace.workspace_id = member.workspace_id
                 WHERE workspace.daemon_id = ?1
                   AND provenance.source_session_id = ?2
                   AND provenance.source_agent_id = ?3
                 ORDER BY member.workspace_id",
            )
            .bind(daemon_id)
            .bind(session_id)
            .bind(agent_id)
            .fetch_all(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("resolve durable membership member: {error}")))?,
            "legacy membership",
        ),
        MemberLocator::Durable {
            daemon_id,
            workspace_id,
            member_id,
        } => (
            query_as::<_, MemberLocation>(
                "SELECT member.workspace_id, member.member_id, member.membership_status,
                        member.runtime_lifecycle, member.membership_source_digest,
                        member.runtime_source_digest
                 FROM agent_workspace_members member
                 JOIN agent_workspaces workspace ON workspace.workspace_id = member.workspace_id
                 WHERE workspace.daemon_id = ?1
                   AND member.workspace_id = ?2 AND member.member_id = ?3",
            )
            .bind(daemon_id)
            .bind(workspace_id)
            .bind(member_id)
            .fetch_all(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("resolve durable workspace member: {error}")))?,
            "durable workspace member",
        ),
    };
    unique_location(locations, identity)
}

fn unique_location(
    mut locations: Vec<MemberLocation>,
    identity: &str,
) -> Result<Option<MemberLocation>, CliError> {
    if locations.len() > 1 {
        return Err(db_error(format!(
            "{identity} resolves to multiple durable workspaces"
        )));
    }
    Ok(locations.pop())
}

const fn managed_kind_label(kind: ManagedAgentKind) -> &'static str {
    match kind {
        ManagedAgentKind::Tui => "tui",
        ManagedAgentKind::Acp => "acp",
        ManagedAgentKind::Codex => "codex",
    }
}

const fn operation_kind_label(kind: AgentWorkspaceMemberOperationKind) -> &'static str {
    match kind {
        AgentWorkspaceMemberOperationKind::RuntimeStop => "runtime_stop",
        AgentWorkspaceMemberOperationKind::MembershipRemove => "membership_remove",
    }
}

const fn operation_outcome_label(outcome: AgentWorkspaceMemberOperationOutcome) -> &'static str {
    match outcome {
        AgentWorkspaceMemberOperationOutcome::Succeeded => "succeeded",
        AgentWorkspaceMemberOperationOutcome::Failed => "failed",
    }
}

fn operation_before_state(
    location: &MemberLocation,
    kind: AgentWorkspaceMemberOperationKind,
) -> &str {
    match kind {
        AgentWorkspaceMemberOperationKind::RuntimeStop => &location.runtime_lifecycle,
        AgentWorkspaceMemberOperationKind::MembershipRemove => &location.membership_status,
    }
}

fn operation_source_marker(
    location: &MemberLocation,
    kind: AgentWorkspaceMemberOperationKind,
) -> &str {
    match kind {
        AgentWorkspaceMemberOperationKind::RuntimeStop => &location.runtime_source_digest,
        AgentWorkspaceMemberOperationKind::MembershipRemove => &location.membership_source_digest,
    }
}

const fn operation_after_state(
    kind: AgentWorkspaceMemberOperationKind,
    outcome: AgentWorkspaceMemberOperationOutcome,
    before_state: &str,
) -> &str {
    match (kind, outcome) {
        (_, AgentWorkspaceMemberOperationOutcome::Failed) => before_state,
        (AgentWorkspaceMemberOperationKind::RuntimeStop, _) => "completed",
        (AgentWorkspaceMemberOperationKind::MembershipRemove, _) => "removed",
    }
}
