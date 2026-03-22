use std::env;
use std::path::Path;
use std::path::PathBuf;

use crate::create::{CreateWorkflowState, read_create_state};
use crate::hooks::protocol::context::{
    NormalizedEvent, NormalizedHookContext, SessionContext, SkillContext,
};
use crate::run::context::RunContext;
use crate::run::workflow::{self as runner_workflow, RunnerWorkflowState};

#[derive(Debug, Clone, Default)]
pub(super) struct HydratedHookState {
    pub(super) run_dir: Option<PathBuf>,
    pub(super) run: Option<RunContext>,
    pub(super) runner_state: Option<RunnerWorkflowState>,
    pub(super) create_state: Option<CreateWorkflowState>,
}

impl HydratedHookState {
    pub(super) fn from_skill(skill: &SkillContext) -> Self {
        let mut state = Self::default();
        state.load_run_context();
        state.load_runner_state();
        state.load_create_state(skill);
        state
    }

    fn load_run_context(&mut self) {
        if let Some(run_directory) = self.run_dir.clone() {
            self.load_run_context_from_dir(&run_directory);
            return;
        }
        self.load_current_run_context();
    }

    fn load_runner_state(&mut self) {
        let run_directory = self.runner_state_dir();
        let Some(run_directory) = run_directory else {
            return;
        };

        self.read_runner_state(&run_directory);
    }

    fn load_create_state(&mut self, skill: &SkillContext) {
        if skill.is_create {
            self.read_create_state();
        }
    }

    fn load_run_context_from_dir(&mut self, run_directory: &Path) {
        self.run = RunContext::from_run_dir(run_directory).ok();
    }

    fn load_current_run_context(&mut self) {
        if let Ok(Some(run_context)) = RunContext::from_current() {
            self.run_dir = Some(run_context.layout.run_dir());
            self.run = Some(run_context);
        }
    }

    fn runner_state_dir(&self) -> Option<PathBuf> {
        self.run
            .as_ref()
            .map(|run_context| run_context.layout.run_dir())
            .or_else(|| self.run_dir.clone())
    }

    fn read_runner_state(&mut self, run_directory: &Path) {
        self.runner_state = runner_workflow::read_runner_state(run_directory)
            .ok()
            .flatten();
    }

    fn read_create_state(&mut self) {
        self.create_state = read_create_state().ok().flatten();
    }
}

pub(crate) fn prepare_normalized_context(
    mut normalized: NormalizedHookContext,
    skill: &str,
    default_event: NormalizedEvent,
) -> NormalizedHookContext {
    normalized.skill = SkillContext::from_skill_name(skill);
    if normalized.event.is_unspecified() {
        normalized.event = default_event;
    }
    normalized
}

pub(super) fn hydrate_normalized_context(
    mut normalized: NormalizedHookContext,
) -> NormalizedHookContext {
    normalized.session = hydrate_session(normalized.session);
    normalized
}

fn hydrate_session(mut session: SessionContext) -> SessionContext {
    if session.cwd.is_none() {
        session.cwd = Some(env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    }
    session
}
