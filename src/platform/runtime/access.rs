use std::borrow::Cow;

/// Borrowed access details for the universal control plane API.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ControlPlaneAccess<'a> {
    pub addr: Cow<'a, str>,
    pub admin_token: Option<&'a str>,
}
