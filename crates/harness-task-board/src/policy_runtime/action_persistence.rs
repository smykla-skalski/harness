#[cfg(any(test, feature = "test-support"))]
use std::path::PathBuf;
use std::sync::Arc;

use chrono::Utc;

use harness_kernel::errors::CliError;

use super::handoff_outbox::HandoffRecord;
#[cfg(any(test, feature = "test-support"))]
use super::handoff_outbox::PolicyHandoffOutbox;
#[cfg(any(test, feature = "test-support"))]
use super::inbox::PolicyEventInbox;
use super::models::PolicyWorkflowEvent;
use super::notification::NotificationRecord;
#[cfg(any(test, feature = "test-support"))]
use super::notification::PolicyNotificationOutbox;
use super::store::PolicyActionStore;
#[cfg(any(test, feature = "test-support"))]
use super::task_creation::PolicyTaskCreationOutbox;
use super::task_creation::TaskCreationRecord;

#[derive(Clone)]
pub(crate) enum PolicyActionPersistence {
    #[cfg(any(test, feature = "test-support"))]
    LegacyFiles(PathBuf),
    Database(Arc<dyn PolicyActionStore>),
}

impl PolicyActionPersistence {
    #[must_use]
    #[cfg(any(test, feature = "test-support"))]
    pub(crate) fn legacy_files(root: PathBuf) -> Self {
        Self::LegacyFiles(root)
    }

    #[must_use]
    pub(crate) fn database(database: Arc<dyn PolicyActionStore>) -> Self {
        Self::Database(database)
    }

    pub(crate) async fn record_handoff(
        &self,
        record: HandoffRecord,
        event: PolicyWorkflowEvent,
    ) -> Result<(), CliError> {
        let now = Utc::now();
        match self {
            #[cfg(any(test, feature = "test-support"))]
            Self::LegacyFiles(root) => {
                PolicyHandoffOutbox::new(root.clone()).record_at(record, now)?;
                PolicyEventInbox::new(root.clone()).publish_at(event, now)
            }
            Self::Database(database) => {
                database.record_handoff_at(record, now).await?;
                database.publish_event_at(event, now).await?;
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
            #[cfg(any(test, feature = "test-support"))]
            Self::LegacyFiles(root) => {
                PolicyNotificationOutbox::new(root.clone()).record_at(record, now)
            }
            Self::Database(database) => database.record_notification_at(record, now).await,
        }
    }

    pub(crate) async fn record_task_creation(
        &self,
        record: TaskCreationRecord,
    ) -> Result<(), CliError> {
        let now = Utc::now();
        match self {
            #[cfg(any(test, feature = "test-support"))]
            Self::LegacyFiles(root) => {
                PolicyTaskCreationOutbox::new(root.clone()).record_at(record, now)
            }
            Self::Database(database) => database.record_task_creation_at(record, now).await,
        }
    }
}
