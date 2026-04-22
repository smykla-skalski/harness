#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpRouteMethod {
    Get,
    Post,
    Put,
    Delete,
}

impl HttpRouteMethod {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Get => "GET",
            Self::Post => "POST",
            Self::Put => "PUT",
            Self::Delete => "DELETE",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpRouteParity {
    Rpc { ws_method: &'static str },
    Exempt { reason: &'static str },
}

impl HttpRouteParity {
    #[must_use]
    pub const fn ws_method(self) -> Option<&'static str> {
        match self {
            Self::Rpc { ws_method } => Some(ws_method),
            Self::Exempt { .. } => None,
        }
    }

    #[must_use]
    pub const fn exemption_reason(self) -> Option<&'static str> {
        match self {
            Self::Rpc { .. } => None,
            Self::Exempt { reason } => Some(reason),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HttpApiRouteContract {
    pub method: HttpRouteMethod,
    pub path: &'static str,
    pub parity: HttpRouteParity,
    pub swift_client_exposed: bool,
}

pub mod http_paths;
mod routes;
#[cfg(test)]
mod tests;
pub mod ws_methods;

pub use routes::HTTP_API_CONTRACT;

#[must_use]
pub fn mapped_ws_methods() -> Vec<&'static str> {
    HTTP_API_CONTRACT
        .iter()
        .filter_map(|route| route.parity.ws_method())
        .collect()
}

#[must_use]
pub fn explicit_exemptions() -> Vec<&'static HttpApiRouteContract> {
    HTTP_API_CONTRACT
        .iter()
        .filter(|route| matches!(route.parity, HttpRouteParity::Exempt { .. }))
        .collect()
}
