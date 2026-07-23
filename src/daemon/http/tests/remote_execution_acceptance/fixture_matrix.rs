use super::fixture::{AcceptanceFixture, FORK_REPOSITORY, HOST_ID, REPOSITORY, TOKEN_ENV};
use crate::daemon::http::DaemonHttpState;
use crate::daemon::task_board_remote_transport::controller_authority_test_support::{
    TestTlsMaterial, remote_host_config,
};
use crate::task_board::{
    TaskBoardLocalExecutionHostConfig, TaskBoardLocalExecutionRepositoryConfig,
    TaskBoardOrchestratorWorkflow, TaskBoardPhaseCapabilityProfile,
    TaskBoardRepositoryAutomationConfig,
};

impl AcceptanceFixture {
    pub(super) async fn configure_matrix_controller(
        &self,
        controller: &DaemonHttpState,
        endpoint: &str,
        tls: &TestTlsMaterial,
    ) {
        let db = controller
            .async_db
            .get()
            .expect("matrix controller async database");
        let mut settings = db
            .task_board_orchestrator_settings()
            .await
            .expect("load matrix controller settings");
        settings.execution_hosts = vec![remote_host_config(
            endpoint,
            tls,
            &format!("env://{TOKEN_ENV}"),
            true,
        )];
        settings.repositories = [FORK_REPOSITORY, REPOSITORY]
            .into_iter()
            .map(|repository| TaskBoardRepositoryAutomationConfig {
                repository: repository.into(),
                enabled: true,
                workflows: vec![
                    TaskBoardOrchestratorWorkflow::DefaultTask,
                    TaskBoardOrchestratorWorkflow::PrFix,
                    TaskBoardOrchestratorWorkflow::PrReview,
                    TaskBoardOrchestratorWorkflow::Review,
                ],
                preferred_host_id: Some(HOST_ID.into()),
                execution_checkout_path: None,
            })
            .collect();
        db.replace_task_board_orchestrator_settings(&settings)
            .await
            .expect("configure matrix controller");
    }

    pub(super) async fn configure_matrix_executor(&self, executor: &DaemonHttpState) {
        let db = executor
            .async_db
            .get()
            .expect("matrix executor async database");
        let mut settings = db
            .task_board_orchestrator_settings()
            .await
            .expect("load matrix executor settings");
        settings.local_execution_host = TaskBoardLocalExecutionHostConfig {
            enabled: true,
            host_id: HOST_ID.into(),
            capacity: 1,
            repositories: [FORK_REPOSITORY, REPOSITORY]
                .into_iter()
                .map(|repository| TaskBoardLocalExecutionRepositoryConfig {
                    repository: repository.into(),
                    checkout_path: if repository == FORK_REPOSITORY {
                        &self.executor_fork_checkout
                    } else {
                        &self.executor_checkout
                    }
                    .to_string_lossy()
                    .into_owned(),
                })
                .collect(),
            runtimes: vec!["codex".into()],
            capabilities: vec![
                TaskBoardPhaseCapabilityProfile::ImplementationWrite,
                TaskBoardPhaseCapabilityProfile::ReviewReadOnly,
                TaskBoardPhaseCapabilityProfile::EvaluateReadOnly,
            ],
        };
        db.replace_task_board_orchestrator_settings(&settings)
            .await
            .expect("configure matrix executor");
    }
}
