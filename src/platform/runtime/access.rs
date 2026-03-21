use std::borrow::Cow;

/// Borrowed access details for the universal control plane API.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ControlPlaneAccess<'a> {
    pub addr: Cow<'a, str>,
    pub admin_token: Option<&'a str>,
}

/// Borrowed access details for the universal XDS endpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct XdsAccess<'a> {
    pub ip: &'a str,
    pub port: u16,
}
