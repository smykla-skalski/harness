//! Serde-transparent newtypes for the four policy-graph identifier namespaces.
//!
//! A policy graph mixes node, edge, group, and port identifiers, all of which
//! were plain `String`s - nothing stopped a node id flowing into a port slot or
//! an edge's `from_node`. These wrappers give each namespace a distinct type so
//! the compiler rejects the mixups, while `#[serde(transparent)]` keeps every id
//! on the wire as the bare string it has always been (no schema bump).
//!
//! Each wrapper carries the same small surface: construction from anything
//! `Into<String>`, a borrowed `as_str`, owned `into_string`, `Display`, and the
//! `From`/`AsRef`/`Borrow`/`PartialEq<str>` impls that let the wrappers stand in
//! for `&str` at the `HashMap`/comparison sites that index graphs by id. The
//! impls are written out per type, not macro-generated, so each id namespace
//! stays explicit and independently deletable.

use std::borrow::Borrow;
use std::fmt;

use serde::{Deserialize, Serialize};

/// Identifies a node within a policy graph (`PolicyGraphNode::id`, an edge's
/// `from_node`/`to_node`, a group's members, a layout entry's `node_id`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct PolicyGraphNodeId(String);

/// Identifies an edge within a policy graph (`PolicyGraphEdge::id`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct PolicyGraphEdgeId(String);

/// Identifies a node group (`PolicyGraphGroup::id`, a node's `group_id`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct PolicyGraphGroupId(String);

/// Identifies a port on a node (`input_ports`/`output_ports`, an edge's
/// `from_port`/`to_port`, a switch arm's `port`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct PolicyGraphPortId(String);

impl PolicyGraphNodeId {
    /// Wrap any string-like value as a node id.
    #[must_use]
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    /// Borrow the underlying id text.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Consume the wrapper, returning the owned id text.
    #[must_use]
    pub fn into_string(self) -> String {
        self.0
    }
}

impl fmt::Display for PolicyGraphNodeId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl From<String> for PolicyGraphNodeId {
    fn from(value: String) -> Self {
        Self(value)
    }
}

impl From<&str> for PolicyGraphNodeId {
    fn from(value: &str) -> Self {
        Self(value.to_owned())
    }
}

impl AsRef<str> for PolicyGraphNodeId {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

impl Borrow<str> for PolicyGraphNodeId {
    fn borrow(&self) -> &str {
        &self.0
    }
}

impl PartialEq<str> for PolicyGraphNodeId {
    fn eq(&self, other: &str) -> bool {
        self.0 == other
    }
}

impl PartialEq<&str> for PolicyGraphNodeId {
    fn eq(&self, other: &&str) -> bool {
        self.0 == *other
    }
}

impl PolicyGraphEdgeId {
    /// Wrap any string-like value as an edge id.
    #[must_use]
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    /// Borrow the underlying id text.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Consume the wrapper, returning the owned id text.
    #[must_use]
    pub fn into_string(self) -> String {
        self.0
    }
}

impl fmt::Display for PolicyGraphEdgeId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl From<String> for PolicyGraphEdgeId {
    fn from(value: String) -> Self {
        Self(value)
    }
}

impl From<&str> for PolicyGraphEdgeId {
    fn from(value: &str) -> Self {
        Self(value.to_owned())
    }
}

impl AsRef<str> for PolicyGraphEdgeId {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

impl Borrow<str> for PolicyGraphEdgeId {
    fn borrow(&self) -> &str {
        &self.0
    }
}

impl PartialEq<str> for PolicyGraphEdgeId {
    fn eq(&self, other: &str) -> bool {
        self.0 == other
    }
}

impl PartialEq<&str> for PolicyGraphEdgeId {
    fn eq(&self, other: &&str) -> bool {
        self.0 == *other
    }
}

impl PolicyGraphGroupId {
    /// Wrap any string-like value as a group id.
    #[must_use]
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    /// Borrow the underlying id text.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Consume the wrapper, returning the owned id text.
    #[must_use]
    pub fn into_string(self) -> String {
        self.0
    }
}

impl fmt::Display for PolicyGraphGroupId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl From<String> for PolicyGraphGroupId {
    fn from(value: String) -> Self {
        Self(value)
    }
}

impl From<&str> for PolicyGraphGroupId {
    fn from(value: &str) -> Self {
        Self(value.to_owned())
    }
}

impl AsRef<str> for PolicyGraphGroupId {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

impl Borrow<str> for PolicyGraphGroupId {
    fn borrow(&self) -> &str {
        &self.0
    }
}

impl PartialEq<str> for PolicyGraphGroupId {
    fn eq(&self, other: &str) -> bool {
        self.0 == other
    }
}

impl PartialEq<&str> for PolicyGraphGroupId {
    fn eq(&self, other: &&str) -> bool {
        self.0 == *other
    }
}

impl PolicyGraphPortId {
    /// Wrap any string-like value as a port id.
    #[must_use]
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    /// Borrow the underlying id text.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Consume the wrapper, returning the owned id text.
    #[must_use]
    pub fn into_string(self) -> String {
        self.0
    }
}

impl fmt::Display for PolicyGraphPortId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl From<String> for PolicyGraphPortId {
    fn from(value: String) -> Self {
        Self(value)
    }
}

impl From<&str> for PolicyGraphPortId {
    fn from(value: &str) -> Self {
        Self(value.to_owned())
    }
}

impl AsRef<str> for PolicyGraphPortId {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

impl Borrow<str> for PolicyGraphPortId {
    fn borrow(&self) -> &str {
        &self.0
    }
}

impl PartialEq<str> for PolicyGraphPortId {
    fn eq(&self, other: &str) -> bool {
        self.0 == other
    }
}

impl PartialEq<&str> for PolicyGraphPortId {
    fn eq(&self, other: &&str) -> bool {
        self.0 == *other
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_serialize_transparently_as_bare_strings() {
        assert_eq!(
            serde_json::to_string(&PolicyGraphNodeId::new("n-1")).unwrap(),
            "\"n-1\""
        );
        assert_eq!(
            serde_json::to_string(&PolicyGraphEdgeId::new("e-1")).unwrap(),
            "\"e-1\""
        );
        assert_eq!(
            serde_json::to_string(&PolicyGraphGroupId::new("g-1")).unwrap(),
            "\"g-1\""
        );
        assert_eq!(
            serde_json::to_string(&PolicyGraphPortId::new("p-1")).unwrap(),
            "\"p-1\""
        );
    }

    #[test]
    fn ids_deserialize_from_bare_strings() {
        let node: PolicyGraphNodeId = serde_json::from_str("\"n-7\"").unwrap();
        assert_eq!(node.as_str(), "n-7");
        let port: PolicyGraphPortId = serde_json::from_str("\"in\"").unwrap();
        assert_eq!(port, "in");
    }

    #[test]
    fn ids_round_trip_through_a_vec() {
        let ids = vec![PolicyGraphNodeId::new("a"), PolicyGraphNodeId::new("b")];
        let json = serde_json::to_string(&ids).unwrap();
        assert_eq!(json, "[\"a\",\"b\"]");
        let back: Vec<PolicyGraphNodeId> = serde_json::from_str(&json).unwrap();
        assert_eq!(back, ids);
    }

    #[test]
    fn string_interop_supports_index_and_compare() {
        use std::collections::HashMap;

        let mut by_id: HashMap<PolicyGraphNodeId, u8> = HashMap::new();
        by_id.insert(PolicyGraphNodeId::new("n-1"), 9);
        // Borrow<str> lets a graph indexed by typed id be probed with a bare &str.
        assert_eq!(by_id.get("n-1"), Some(&9));

        let id = PolicyGraphNodeId::new("n-1");
        assert_eq!(id, "n-1");
        assert_eq!(id.to_string(), "n-1");
        assert_eq!(PolicyGraphNodeId::from("n-2").as_str(), "n-2");
    }
}
