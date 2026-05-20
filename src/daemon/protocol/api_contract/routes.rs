use std::sync::LazyLock;

use super::{
    HttpApiRouteContract, routes_dependency_updates, routes_sessions_infra, routes_task_board,
    routes_tasks_agents_voice,
};

pub static HTTP_API_CONTRACT: LazyLock<Vec<HttpApiRouteContract>> = LazyLock::new(|| {
    let mut v = Vec::from(routes_sessions_infra::ROUTES);
    v.extend_from_slice(routes_tasks_agents_voice::ROUTES);
    v.extend_from_slice(routes_dependency_updates::ROUTES);
    v.extend_from_slice(routes_task_board::ROUTES);
    v
});
