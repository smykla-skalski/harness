use std::sync::LazyLock;

use super::{HttpApiRouteContract, routes_sessions_infra, routes_tasks_agents_voice};

pub static HTTP_API_CONTRACT: LazyLock<Vec<HttpApiRouteContract>> = LazyLock::new(|| {
    let mut v = Vec::from(routes_sessions_infra::ROUTES);
    v.extend_from_slice(routes_tasks_agents_voice::ROUTES);
    v
});
