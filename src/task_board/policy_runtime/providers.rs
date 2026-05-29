use std::collections::BTreeMap;
use std::sync::Arc;

use crate::errors::{CliError, CliErrorKind};

use super::models::{PolicyActionDescriptor, PolicyRunSubject, PolicyRunTrigger};

pub trait PolicyActionProvider: Send + Sync {
    fn domain(&self) -> &'static str;

    fn execute(
        &self,
        action: &PolicyActionDescriptor,
        ctx: &PolicyExecutionContext,
    ) -> Result<PolicyActionExecution, CliError>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PolicyExecutionContext {
    pub workflow_id: String,
    pub subject: PolicyRunSubject,
    pub trigger: PolicyRunTrigger,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PolicyActionExecution {
    pub action_key: String,
}

pub struct PolicyProviderRegistry {
    providers: BTreeMap<String, Arc<dyn PolicyActionProvider>>,
}

impl Default for PolicyProviderRegistry {
    fn default() -> Self {
        Self {
            providers: BTreeMap::new(),
        }
    }
}

impl PolicyProviderRegistry {
    pub fn register<P>(&mut self, provider: P)
    where
        P: PolicyActionProvider + 'static,
    {
        self.providers
            .insert(provider.domain().to_owned(), Arc::new(provider));
    }

    pub fn execute(
        &self,
        action: &PolicyActionDescriptor,
        ctx: &PolicyExecutionContext,
    ) -> Result<PolicyActionExecution, CliError> {
        let provider = self.providers.get(&action.provider).ok_or_else(|| {
            CliErrorKind::invalid_transition(format!(
                "no policy action provider registered for '{}'",
                action.provider
            ))
        })?;
        provider.execute(action, ctx)
    }
}
