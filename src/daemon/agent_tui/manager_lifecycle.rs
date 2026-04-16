use std::sync::Arc;
use std::thread;

use uuid::Uuid;

use crate::agents::runtime::{AgentRuntime, InitialPromptDelivery, runtime_for_name};
use crate::daemon::bridge::{AgentTuiStartSpec, BridgeCapability, BridgeClient};
use crate::errors::CliError;

use super::manager::{ActiveAgentTui, AgentTuiManagerHandle};
use super::model::{AgentTuiSnapshot, AgentTuiStartRequest, AgentTuiStatus};
use super::process::{AgentTuiProcess, AgentTuiSnapshotContext, snapshot_from_process};
use super::spawn::{
    build_auto_join_prompt, deliver_deferred_prompts, send_initial_prompt, spawn_agent_tui_process,
    wait_for_readiness,
};
use super::support::{
    ResolvedTuiProject, lock_db, resolve_tui_project, resolve_tui_project_async, transcript_path,
};

impl AgentTuiManagerHandle {
    /// Start an agent runtime in a PTY.
    ///
    /// The agent is **not** registered in session state here. Registration
    /// happens when the auto-join skill invocation executes inside the PTY,
    /// preventing the duplicate-registration bug that occurred when both the
    /// daemon and the skill called `join_session`.
    ///
    /// # Errors
    /// Returns [`CliError`] when the daemon DB is unavailable or PTY/process
    /// setup fails.
    pub fn start(
        &self,
        session_id: &str,
        request: &AgentTuiStartRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        if self.state.sandboxed {
            return self.start_via_bridge(session_id, request);
        }

        let profile = request.launch_profile()?;
        let size = request.size()?;
        let tui_id = format!("agent-tui-{}", Uuid::new_v4());
        let project = self.resolve_project(session_id, request.project_dir.as_deref())?;
        let transcript_path = transcript_path(&project.context_root, &profile.runtime, &tui_id);
        let snapshot_context = AgentTuiSnapshotContext {
            session_id,
            agent_id: "",
            tui_id: &tui_id,
            profile: &profile,
            project_dir: &project.project_dir,
            transcript_path: &transcript_path,
        };
        let auto_join = build_auto_join_prompt(
            &profile.runtime,
            session_id,
            request.role,
            request.fallback_role,
            &request.capabilities,
            &tui_id,
            request.name.as_deref(),
            request.persona.as_deref(),
        );
        let process = spawn_agent_tui_process(
            session_id,
            &tui_id,
            profile.clone(),
            &project.project_dir,
            size,
            Some(auto_join.clone()),
        )?;

        let result = self.activate_tui(process, &snapshot_context);
        if let Ok(snapshot) = &result {
            self.spawn_deferred_join(
                snapshot.clone(),
                profile.runtime.clone(),
                &auto_join,
                request,
            );
        }
        result
    }

    /// Spawn a background thread that waits for the readiness callback (or
    /// timeout), then delivers any PTY-based prompts and broadcasts the
    /// `agent_tui_ready` event.
    ///
    /// For `CliPositional`/`CliFlag` runtimes the join prompt was already
    /// injected into the CLI argv, so the thread only waits + broadcasts.
    /// For `PtySend` runtimes it also sends the join via PTY after readiness.
    fn spawn_deferred_join(
        &self,
        snapshot: AgentTuiSnapshot,
        runtime: String,
        auto_join: &str,
        request: &AgentTuiStartRequest,
    ) {
        let delivery = runtime_for_name(&runtime).map_or(
            InitialPromptDelivery::PtySend,
            AgentRuntime::initial_prompt_delivery,
        );
        let pty_auto_join =
            matches!(delivery, InitialPromptDelivery::PtySend).then(|| auto_join.to_string());
        let user_prompt = request
            .prompt
            .as_deref()
            .filter(|value| !value.is_empty())
            .map(ToString::to_string);
        let tui_id = snapshot.tui_id.clone();
        let manager = self.clone();

        thread::spawn(
            #[expect(
                clippy::cognitive_complexity,
                reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
            )]
            move || {
                let Ok(process) = manager.active_process(&tui_id) else {
                    tracing::warn!(tui_id = %tui_id, "deferred join: TUI no longer active");
                    return;
                };
                wait_for_readiness(&process, &runtime, &tui_id);
                if let Some(join_prompt) = &pty_auto_join {
                    deliver_deferred_prompts(
                        &process,
                        &runtime,
                        &tui_id,
                        join_prompt,
                        user_prompt.as_deref(),
                    );
                } else if let Some(prompt) = &user_prompt
                    && let Err(error) = send_initial_prompt(&process, prompt)
                {
                    tracing::warn!(%error, "failed to send user prompt");
                }
                let _ = manager.save_and_broadcast("agent_tui_ready", &snapshot);
            },
        );
    }

    fn activate_tui(
        &self,
        process: AgentTuiProcess,
        context: &AgentTuiSnapshotContext<'_>,
    ) -> Result<AgentTuiSnapshot, CliError> {
        let process = Arc::new(process);
        let snapshot = snapshot_from_process(context, &process, AgentTuiStatus::Running)?;
        self.register_started_snapshot(&snapshot, ActiveAgentTui::new(Some(process)))?;
        Ok(snapshot)
    }

    fn start_via_bridge(
        &self,
        session_id: &str,
        request: &AgentTuiStartRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        let profile = request.launch_profile()?;
        let size = request.size()?;
        let tui_id = format!("agent-tui-{}", Uuid::new_v4());
        let bridge = BridgeClient::for_capability(BridgeCapability::AgentTui)?;
        let project = self.resolve_project(session_id, request.project_dir.as_deref())?;
        let auto_join = build_auto_join_prompt(
            &profile.runtime,
            session_id,
            request.role,
            request.fallback_role,
            &request.capabilities,
            &tui_id,
            request.name.as_deref(),
            request.persona.as_deref(),
        );

        let transcript_path = transcript_path(&project.context_root, &profile.runtime, &tui_id);
        let snapshot = bridge.agent_tui_start(&AgentTuiStartSpec {
            session_id: session_id.to_string(),
            agent_id: String::new(),
            tui_id,
            profile,
            project_dir: project.project_dir,
            transcript_path,
            size,
            prompt: Some(auto_join),
        })?;
        self.register_started_snapshot(&snapshot, ActiveAgentTui::new(None))?;
        Ok(snapshot)
    }

    fn resolve_project(
        &self,
        session_id: &str,
        requested_project_dir: Option<&str>,
    ) -> Result<ResolvedTuiProject, CliError> {
        let session_id_owned = session_id.to_string();
        let requested_project_dir = requested_project_dir.map(ToString::to_string);
        let requested_project_dir_async = requested_project_dir.clone();
        if let Some(result) = self.run_with_async_db(move |async_db| async move {
            resolve_tui_project_async(
                async_db.as_ref(),
                &session_id_owned,
                requested_project_dir_async.as_deref(),
            )
            .await
        }) {
            return result;
        }

        let db = self.db()?;
        let db_guard = lock_db(&db)?;
        resolve_tui_project(&db_guard, session_id, requested_project_dir.as_deref())
    }

    fn register_started_snapshot(
        &self,
        snapshot: &AgentTuiSnapshot,
        active: ActiveAgentTui,
    ) -> Result<(), CliError> {
        let stop_flag = Arc::clone(&active.stop_flag);
        let tui_id = snapshot.tui_id.clone();
        self.active()?.insert(tui_id.clone(), active);
        if let Err(error) = self.save_and_broadcast("agent_tui_started", snapshot) {
            let _ = self.remove_active(&tui_id)?;
            return Err(error);
        }
        self.spawn_live_refresh(tui_id, stop_flag);
        Ok(())
    }
}
