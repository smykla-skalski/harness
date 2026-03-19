use std::borrow::Cow;

use serde::Serialize;

/// Runtime health for a tracked cluster member or backing network.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ClusterMemberHealthRecord<'a> {
    pub name: &'a str,
    pub role: &'a str,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub container: Option<Cow<'a, str>>,
    pub running: bool,
}

/// Structured result for `harness cluster-check`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ClusterHealthReport<'a> {
    pub healthy: bool,
    pub members: Vec<ClusterMemberHealthRecord<'a>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hint: Option<&'static str>,
}
