#[cfg(test)]
use std::path::PathBuf;
use std::sync::Arc;

use async_trait::async_trait;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::reviews_store::PolicyGraphQueries;
use crate::reviews::policy::{ReviewsPolicyActionExecutor, ReviewsPolicyProvider};
use crate::task_board::policy_runtime::handoff::HandoffPolicyProvider;
use crate::task_board::policy_runtime::models::PolicyActionDescriptor;
use crate::task_board::policy_runtime::notification::NotificationPolicyProvider;
use crate::task_board::policy_runtime::providers::{
    PolicyActionExecution, PolicyActionProvider, PolicyExecutionContext, PolicyProviderRegistry,
};
use crate::task_board::policy_runtime::task_creation::TaskCreationPolicyProvider;
use harness_kernel::errors::{CliError, CliErrorKind};

/// Build the legacy file-backed provider registry used by explicit compatibility
/// tests. Production callers use [`build_database_policy_provider_registry`].
#[cfg(test)]
pub(crate) fn build_policy_provider_registry<E>(
    executor: E,
    root: PathBuf,
) -> PolicyProviderRegistry
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    let mut providers = PolicyProviderRegistry::default();
    providers.register(ReviewsPolicyProvider::new(executor));
    providers.register(HandoffPolicyProvider::new(root.clone()));
    providers.register(NotificationPolicyProvider::new(root.clone()));
    providers.register(TaskCreationPolicyProvider::new(root));
    providers
}

/// Build the production registry with every durable non-reviews side effect
/// written to the canonical daemon database.
pub(crate) fn build_database_policy_provider_registry<E>(
    executor: E,
    database: Arc<AsyncDaemonDb>,
) -> PolicyProviderRegistry
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    let mut providers = PolicyProviderRegistry::default();
    providers.register(AutomationControlledPolicyProvider::new(
        ReviewsPolicyProvider::new(executor),
        Arc::clone(&database),
    ));
    providers.register(AutomationControlledPolicyProvider::new(
        HandoffPolicyProvider::new_database(Arc::clone(&database)),
        Arc::clone(&database),
    ));
    providers.register(AutomationControlledPolicyProvider::new(
        NotificationPolicyProvider::new_database(Arc::clone(&database)),
        Arc::clone(&database),
    ));
    providers.register(AutomationControlledPolicyProvider::new(
        TaskCreationPolicyProvider::new_database(Arc::clone(&database)),
        database,
    ));
    providers
}

struct AutomationControlledPolicyProvider<P> {
    provider: P,
    database: Arc<AsyncDaemonDb>,
}

impl<P> AutomationControlledPolicyProvider<P> {
    fn new(provider: P, database: Arc<AsyncDaemonDb>) -> Self {
        Self { provider, database }
    }
}

#[async_trait]
impl<P> PolicyActionProvider for AutomationControlledPolicyProvider<P>
where
    P: PolicyActionProvider,
{
    fn domain(&self) -> &'static str {
        self.provider.domain()
    }

    async fn execute(
        &self,
        action: &PolicyActionDescriptor,
        context: &PolicyExecutionContext,
    ) -> Result<PolicyActionExecution, CliError> {
        let workspace = self.database.load_policy_workspace().await?;
        let enabled = workspace.is_some_and(|workspace| {
            workspace.global_policy_enforcement_enabled && !workspace.spawn_kill_switch
        });
        if !enabled {
            return Err(CliErrorKind::invalid_transition("policy automation is disabled").into());
        }
        self.provider.execute(action, context).await
    }
}
