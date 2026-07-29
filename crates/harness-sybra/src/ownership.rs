use std::collections::BTreeMap;
use std::sync::Arc;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum SybraOperation {
    Rpc { service: String, method: String },
    Events,
    NamedEvent(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SybraOwner {
    Upstream,
    Native,
    Unsupported,
}

/// Immutable routing snapshot consulted before any handler or upstream work.
#[derive(Debug, Clone)]
pub struct SybraOwnershipRegistry {
    default_owner: SybraOwner,
    owners: Arc<BTreeMap<SybraOperation, SybraOwner>>,
}

impl SybraOwnershipRegistry {
    #[must_use]
    pub fn default_upstream() -> Self {
        Self {
            default_owner: SybraOwner::Upstream,
            owners: Arc::new(BTreeMap::new()),
        }
    }

    #[must_use]
    pub fn owner(&self, operation: &SybraOperation) -> SybraOwner {
        self.owners
            .get(operation)
            .copied()
            .unwrap_or(self.default_owner)
    }

    #[must_use]
    pub fn with_owner(self, operation: SybraOperation, owner: SybraOwner) -> Self {
        let mut owners = self.owners.as_ref().clone();
        owners.insert(operation, owner);
        Self {
            default_owner: self.default_owner,
            owners: Arc::new(owners),
        }
    }
}
