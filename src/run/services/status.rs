use std::borrow::Cow;

use serde::Serialize;

use crate::run::state_capture::UniversalDataplaneCollection;

/// Structured service status row for `harness status`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ServiceStatusRecord {
    pub name: String,
    pub status: String,
}

/// Structured cluster-member row for `harness status`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ClusterMemberStatusRecord<'a> {
    pub name: &'a str,
    pub role: &'a str,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub container_ip: Option<&'a str>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cp_api_port: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub xds_port: Option<u16>,
}

/// Structured result for `harness status`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ClusterStatusReport<'a> {
    pub platform: &'static str,
    pub mode: &'static str,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cp_address: Option<Cow<'a, str>>,
    #[serde(default)]
    pub admin_token: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub store_type: Option<&'a str>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub docker_network: Option<&'a str>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cp_image: Option<&'a str>,
    pub members: Vec<ClusterMemberStatusRecord<'a>>,
    #[serde(default)]
    pub services: Vec<ServiceStatusRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dataplanes: Option<UniversalDataplaneCollection>,
}
