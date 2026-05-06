use std::borrow::Borrow;
use std::fmt;

use serde::{Deserialize, Serialize};

use crate::agents::kind::AcpAgentId;

macro_rules! identity_newtype {
    ($(($name:ident, $doc:literal)),+ $(,)?) => {
        $(
            #[doc = $doc]
            #[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
            #[serde(transparent)]
            pub struct $name(String);

            impl $name {
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

            impl From<String> for $name {
                fn from(value: String) -> Self {
                    Self(value)
                }
            }

            impl From<&str> for $name {
                fn from(value: &str) -> Self {
                    Self::new(value)
                }
            }

            impl From<$name> for String {
                fn from(value: $name) -> Self {
                    value.0
                }
            }

            impl AsRef<str> for $name {
                fn as_ref(&self) -> &str {
                    self.as_str()
                }
            }

            impl Borrow<str> for $name {
                fn borrow(&self) -> &str {
                    self.as_str()
                }
            }

            impl fmt::Display for $name {
                fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                    f.write_str(self.as_str())
                }
            }
        )+
    };
}

identity_newtype!(
    (
        HarnessSessionId,
        "Identifier of a harness orchestration session."
    ),
    (
        SessionAgentId,
        "Identifier of an agent registered inside a harness session."
    ),
    (
        ManagedAgentId,
        "Identifier of a live daemon-managed agent instance."
    ),
    (
        RuntimeSessionId,
        "Identifier of a runtime-native log/signal session."
    ),
    (
        AgentDescriptorId,
        "Identifier of a launch/catalog agent descriptor."
    ),
);

impl From<&AcpAgentId> for AgentDescriptorId {
    fn from(value: &AcpAgentId) -> Self {
        Self::new(value.as_str())
    }
}
