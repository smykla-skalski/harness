//! Durable storage for pull request action records, keyed by idempotency id.

use harness_task_board::github::{
    ActionState, PullRequestAction, PullRequestActionFailureClass, PullRequestActionKind,
    PullRequestIdentity, RecordedAction,
};
use harness_workspace::workspace::utc_now;
use sqlx::{query, query_as};

use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};

const SELECT_ACTION: &str = "SELECT id, kind, repository, number, url, head_revision, state, \
     failure_class, detail FROM pull_request_actions WHERE id = ?1";

const UPSERT_ACTION: &str = "INSERT INTO pull_request_actions (
        id, kind, repository, number, url, head_revision, state, failure_class, detail, updated_at
    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
    ON CONFLICT(id) DO UPDATE SET
        kind = excluded.kind,
        repository = excluded.repository,
        number = excluded.number,
        url = excluded.url,
        head_revision = excluded.head_revision,
        state = excluded.state,
        failure_class = excluded.failure_class,
        detail = excluded.detail,
        updated_at = excluded.updated_at";

type ActionRow = (
    String,
    String,
    String,
    i64,
    Option<String>,
    String,
    String,
    Option<String>,
    Option<String>,
);

impl AsyncDaemonDb {
    pub(crate) async fn load_pull_request_action(
        &self,
        id: &str,
    ) -> Result<Option<RecordedAction>, CliError> {
        let row = query_as::<_, ActionRow>(SELECT_ACTION)
            .bind(id)
            .fetch_optional(self.pool())
            .await
            .map_err(|error| db_error(format!("load pull request action: {error}")))?;
        row.map(record_from_row).transpose()
    }

    pub(crate) async fn upsert_pull_request_action(
        &self,
        record: RecordedAction,
    ) -> Result<(), CliError> {
        let (state, failure_class) = state_to_text(record.state);
        let number = i64::try_from(record.action.identity.number).map_err(|error| {
            db_error(format!("pull request action number out of range: {error}"))
        })?;
        query(UPSERT_ACTION)
            .bind(&record.action.id)
            .bind(kind_to_text(record.action.kind))
            .bind(&record.action.identity.repository)
            .bind(number)
            .bind(&record.action.identity.url)
            .bind(&record.action.head_revision)
            .bind(state)
            .bind(failure_class)
            .bind(&record.detail)
            .bind(utc_now())
            .execute(self.pool())
            .await
            .map_err(|error| db_error(format!("upsert pull request action: {error}")))?;
        Ok(())
    }
}

fn record_from_row(row: ActionRow) -> Result<RecordedAction, CliError> {
    let (id, kind, repository, number, url, head_revision, state, failure_class, detail) = row;
    let number = u64::try_from(number)
        .map_err(|error| db_error(format!("pull request action number out of range: {error}")))?;
    let identity = PullRequestIdentity::from_slug(repository, number).with_url(url);
    let action = PullRequestAction {
        id,
        kind: kind_from_text(&kind)?,
        identity,
        head_revision,
    };
    Ok(RecordedAction {
        action,
        state: state_from_text(&state, failure_class)?,
        detail,
    })
}

fn kind_to_text(kind: PullRequestActionKind) -> &'static str {
    match kind {
        PullRequestActionKind::Approve => "approve",
        PullRequestActionKind::Merge => "merge",
        PullRequestActionKind::Comment => "comment",
    }
}

fn kind_from_text(text: &str) -> Result<PullRequestActionKind, CliError> {
    match text {
        "approve" => Ok(PullRequestActionKind::Approve),
        "merge" => Ok(PullRequestActionKind::Merge),
        "comment" => Ok(PullRequestActionKind::Comment),
        other => Err(db_error(format!(
            "unknown pull request action kind: {other}"
        ))),
    }
}

fn state_to_text(state: ActionState) -> (&'static str, Option<&'static str>) {
    match state {
        ActionState::Pending => ("pending", None),
        ActionState::Uncertain => ("uncertain", None),
        ActionState::Succeeded => ("succeeded", None),
        ActionState::Failed(class) => ("failed", Some(failure_class_to_text(class))),
    }
}

fn state_from_text(state: &str, failure_class: Option<String>) -> Result<ActionState, CliError> {
    match state {
        "pending" => Ok(ActionState::Pending),
        "uncertain" => Ok(ActionState::Uncertain),
        "succeeded" => Ok(ActionState::Succeeded),
        "failed" => {
            let class = failure_class.ok_or_else(|| {
                db_error("failed pull request action row is missing its failure class")
            })?;
            Ok(ActionState::Failed(failure_class_from_text(&class)?))
        }
        other => Err(db_error(format!(
            "unknown pull request action state: {other}"
        ))),
    }
}

fn failure_class_to_text(class: PullRequestActionFailureClass) -> &'static str {
    match class {
        PullRequestActionFailureClass::Transient => "transient",
        PullRequestActionFailureClass::Permanent => "permanent",
    }
}

fn failure_class_from_text(text: &str) -> Result<PullRequestActionFailureClass, CliError> {
    match text {
        "transient" => Ok(PullRequestActionFailureClass::Transient),
        "permanent" => Ok(PullRequestActionFailureClass::Permanent),
        other => Err(db_error(format!(
            "unknown pull request action failure class: {other}"
        ))),
    }
}
