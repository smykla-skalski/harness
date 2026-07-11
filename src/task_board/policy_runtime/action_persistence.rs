#[cfg(test)]
use std::path::PathBuf;
use std::sync::Arc;

use chrono::Utc;

use crate::daemon::db::AsyncDaemonDb;
use crate::errors::CliError;

use super::handoff_outbox::HandoffRecord;
#[cfg(test)]
use super::handoff_outbox::PolicyHandoffOutbox;
#[cfg(test)]
use super::inbox::PolicyEventInbox;
use super::models::PolicyWorkflowEvent;
use super::notification::NotificationRecord;
#[cfg(test)]
use super::notification::PolicyNotificationOutbox;
#[cfg(test)]
use super::task_creation::PolicyTaskCreationOutbox;
use super::task_creation::TaskCreationRecord;

#[derive(Clone)]
pub(crate) enum PolicyActionPersistence {
    #[cfg(test)]
    LegacyFiles(PathBuf),
    Database(Arc<AsyncDaemonDb>),
}

impl PolicyActionPersistence {
    #[must_use]
    #[cfg(test)]
    pub(crate) fn legacy_files(root: PathBuf) -> Self {
        Self::LegacyFiles(root)
    }

    #[must_use]
    pub(crate) fn database(database: Arc<AsyncDaemonDb>) -> Self {
        Self::Database(database)
    }

    pub(crate) async fn record_handoff(
        &self,
        record: HandoffRecord,
        event: PolicyWorkflowEvent,
    ) -> Result<(), CliError> {
        let now = Utc::now();
        match self {
            #[cfg(test)]
            Self::LegacyFiles(root) => {
                PolicyHandoffOutbox::new(root.clone()).record_at(record, now)?;
                PolicyEventInbox::new(root.clone()).publish_at(event, now)
            }
            Self::Database(database) => {
                database.record_policy_handoff_at(record, now).await?;
                database.publish_policy_event_at(event, now).await?;
                Ok(())
            }
        }
    }

    pub(crate) async fn record_notification(
        &self,
        record: NotificationRecord,
    ) -> Result<(), CliError> {
        let now = Utc::now();
        match self {
            #[cfg(test)]
            Self::LegacyFiles(root) => {
                PolicyNotificationOutbox::new(root.clone()).record_at(record, now)
            }
            Self::Database(database) => database
                .record_policy_notification_at(record, now)
                .await
                .map(|_| ()),
        }
    }

    pub(crate) async fn record_task_creation(
        &self,
        record: TaskCreationRecord,
    ) -> Result<(), CliError> {
        let now = Utc::now();
        match self {
            #[cfg(test)]
            Self::LegacyFiles(root) => {
                PolicyTaskCreationOutbox::new(root.clone()).record_at(record, now)
            }
            Self::Database(database) => database
                .record_policy_task_creation_at(record, now)
                .await
                .map(|_| ()),
        }
    }
}
