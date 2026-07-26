use std::fmt;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Instant;

use axum::Router;
use axum::body::Body;
use axum::extract::{ConnectInfo, State};
use axum::http::{Method, Request};
use axum::response::Response;
use axum::routing::any;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use super::super::{DaemonConnectInfo, DaemonHttpState};
use super::{
    CompanionRouteConfig, MAX_CONCURRENT_COMPANION_REQUESTS, client, forward, rate_limit,
};

/// Live companion routing: the validated target plus the pooled client used to
/// reach it. Cloning shares the HTTP/1 and HTTP/2 connection pools.
#[derive(Clone)]
pub struct CompanionRouter {
    inner: Arc<CompanionRouterInner>,
}

struct CompanionRouterInner {
    config: CompanionRouteConfig,
    clients: client::CompanionClients,
    oauth_start_limiter: Mutex<rate_limit::OAuthStartRateLimiter>,
    request_permits: Arc<Semaphore>,
}

impl fmt::Debug for CompanionRouter {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CompanionRouter")
            .field("config", &self.inner.config)
            .finish_non_exhaustive()
    }
}

impl CompanionRouter {
    #[must_use]
    pub fn new(config: CompanionRouteConfig) -> Self {
        Self::with_request_limit(config, MAX_CONCURRENT_COMPANION_REQUESTS)
    }

    fn with_request_limit(config: CompanionRouteConfig, max_concurrency: usize) -> Self {
        Self {
            inner: Arc::new(CompanionRouterInner {
                config,
                clients: client::CompanionClients::new(),
                oauth_start_limiter: Mutex::new(rate_limit::OAuthStartRateLimiter::new()),
                request_permits: Arc::new(Semaphore::new(max_concurrency)),
            }),
        }
    }

    #[cfg(test)]
    pub(crate) fn with_request_limit_for_tests(
        config: CompanionRouteConfig,
        max_concurrency: usize,
    ) -> Self {
        Self::with_request_limit(config, max_concurrency)
    }

    pub(crate) fn try_request_permit(&self) -> Option<OwnedSemaphorePermit> {
        Arc::clone(&self.inner.request_permits)
            .try_acquire_owned()
            .ok()
    }

    /// Whether the given matched route path is served by the companion.
    #[must_use]
    pub(crate) fn owns_route(&self, route_path: &str) -> bool {
        self.inner.config.owns_route(route_path)
    }
}

/// Register every companion route pattern on the daemon router.
///
/// Merge these *after* the remote authentication layer is applied: the
/// companion authenticates its own users, and its paths carry no entry in
/// `HTTP_API_CONTRACT` for the daemon's scope table to authorize against.
pub(in crate::daemon::http) fn companion_routes(
    router: &CompanionRouter,
) -> Router<DaemonHttpState> {
    router
        .inner
        .config
        .routes()
        .into_iter()
        .fold(Router::new(), |router, route| {
            router.route(&route, any(proxy_request))
        })
}

async fn proxy_request(
    ConnectInfo(connect_info): ConnectInfo<DaemonConnectInfo>,
    State(state): State<DaemonHttpState>,
    request: Request<Body>,
) -> Response {
    let Some(companion) = state.companion.clone() else {
        // Unreachable through the router, which only registers these routes
        // when a companion is configured, but a 502 beats a panic if it ever is.
        return forward::companion_unconfigured_response();
    };
    let peer_addr = connect_info.remote_addr();
    if matches!(request.method(), &Method::GET | &Method::HEAD)
        && companion.inner.config.is_oauth_start(request.uri().path())
    {
        let retry_after = companion
            .inner
            .oauth_start_limiter
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .admit(peer_addr.ip(), Instant::now())
            .err();
        if let Some(retry_after_seconds) = retry_after {
            return rate_limit::rate_limited_response(retry_after_seconds);
        }
    }
    let client = companion.inner.clients.for_version(request.version());
    forward::forward_to_companion(
        &companion.inner.config,
        client,
        peer_addr,
        request,
    )
    .await
}
