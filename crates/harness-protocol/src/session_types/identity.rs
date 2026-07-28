use std::borrow::Borrow;
use std::fmt;

use serde::{Deserialize, Serialize};

use crate::agents::kind::AcpAgentId;

/// Identifier of a harness orchestration session.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct HarnessSessionId(String);

impl HarnessSessionId {
    #[must_use]
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        self.0.as_str()
    }

    #[must_use]
    pub fn into_inner(self) -> String {
        self.0
    }
}

impl From<String> for HarnessSessionId {
    fn from(value: String) -> Self {
        Self(value)
    }
}

impl From<&str> for HarnessSessionId {
    fn from(value: &str) -> Self {
        Self::new(value)
    }
}

impl From<HarnessSessionId> for String {
    fn from(value: HarnessSessionId) -> Self {
        value.0
    }
}

impl AsRef<str> for HarnessSessionId {
    fn as_ref(&self) -> &str {
        self.as_str()
    }
}

impl Borrow<str> for HarnessSessionId {
    fn borrow(&self) -> &str {
        self.as_str()
    }
}

impl fmt::Display for HarnessSessionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Identifier of an agent registered inside a harness session.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SessionAgentId(String);

impl SessionAgentId {
    #[must_use]
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        self.0.as_str()
    }

    #[must_use]
    pub fn into_inner(self) -> String {
        self.0
    }
}

impl From<String> for SessionAgentId {
    fn from(value: String) -> Self {
        Self(value)
    }
}

impl From<&str> for SessionAgentId {
    fn from(value: &str) -> Self {
        Self::new(value)
    }
}

impl From<SessionAgentId> for String {
    fn from(value: SessionAgentId) -> Self {
        value.0
    }
}

impl AsRef<str> for SessionAgentId {
    fn as_ref(&self) -> &str {
        self.as_str()
    }
}

impl Borrow<str> for SessionAgentId {
    fn borrow(&self) -> &str {
        self.as_str()
    }
}

impl fmt::Display for SessionAgentId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Identifier of a live daemon-managed agent instance.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ManagedAgentId(String);

impl ManagedAgentId {
    #[must_use]
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        self.0.as_str()
    }

    #[must_use]
    pub fn into_inner(self) -> String {
        self.0
    }
}

impl From<String> for ManagedAgentId {
    fn from(value: String) -> Self {
        Self(value)
    }
}

impl From<&str> for ManagedAgentId {
    fn from(value: &str) -> Self {
        Self::new(value)
    }
}

impl From<ManagedAgentId> for String {
    fn from(value: ManagedAgentId) -> Self {
        value.0
    }
}

impl AsRef<str> for ManagedAgentId {
    fn as_ref(&self) -> &str {
        self.as_str()
    }
}

impl Borrow<str> for ManagedAgentId {
    fn borrow(&self) -> &str {
        self.as_str()
    }
}

impl fmt::Display for ManagedAgentId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Identifier of a runtime-native log/signal session.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RuntimeSessionId(String);

impl RuntimeSessionId {
    #[must_use]
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        self.0.as_str()
    }

    #[must_use]
    pub fn into_inner(self) -> String {
        self.0
    }
}

impl From<String> for RuntimeSessionId {
    fn from(value: String) -> Self {
        Self(value)
    }
}

impl From<&str> for RuntimeSessionId {
    fn from(value: &str) -> Self {
        Self::new(value)
    }
}

impl From<RuntimeSessionId> for String {
    fn from(value: RuntimeSessionId) -> Self {
        value.0
    }
}

impl AsRef<str> for RuntimeSessionId {
    fn as_ref(&self) -> &str {
        self.as_str()
    }
}

impl Borrow<str> for RuntimeSessionId {
    fn borrow(&self) -> &str {
        self.as_str()
    }
}

impl fmt::Display for RuntimeSessionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Identifier of a launch/catalog agent descriptor.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct AgentDescriptorId(String);

impl AgentDescriptorId {
    #[must_use]
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        self.0.as_str()
    }

    #[must_use]
    pub fn into_inner(self) -> String {
        self.0
    }
}

impl From<String> for AgentDescriptorId {
    fn from(value: String) -> Self {
        Self(value)
    }
}

impl From<&str> for AgentDescriptorId {
    fn from(value: &str) -> Self {
        Self::new(value)
    }
}

impl From<AgentDescriptorId> for String {
    fn from(value: AgentDescriptorId) -> Self {
        value.0
    }
}

impl AsRef<str> for AgentDescriptorId {
    fn as_ref(&self) -> &str {
        self.as_str()
    }
}

impl Borrow<str> for AgentDescriptorId {
    fn borrow(&self) -> &str {
        self.as_str()
    }
}

impl fmt::Display for AgentDescriptorId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl From<&AcpAgentId> for AgentDescriptorId {
    fn from(value: &AcpAgentId) -> Self {
        Self::new(value.as_str())
    }
}
