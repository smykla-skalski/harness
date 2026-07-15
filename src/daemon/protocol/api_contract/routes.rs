use std::sync::LazyLock;

use super::{
    HttpApiRouteContract, routes_policy_transfer, routes_remote, routes_reviews,
    routes_sessions_infra, routes_task_board, routes_tasks_agents_voice,
};

pub static HTTP_API_CONTRACT: LazyLock<Vec<HttpApiRouteContract>> = LazyLock::new(|| {
    let mut v = Vec::from(routes_sessions_infra::ROUTES);
    v.extend_from_slice(routes_remote::ROUTES);
    v.extend_from_slice(routes_tasks_agents_voice::ROUTES);
    v.extend_from_slice(routes_reviews::ROUTES);
    v.extend_from_slice(routes_task_board::ROUTES);
    v.extend_from_slice(routes_policy_transfer::ROUTES);
    v
});
