use std::env;
use std::path::PathBuf;

use tracing::warn;

use crate::authoring::{AuthorWorkflowState, read_author_state};
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
    pub(super) author_state: Option<AuthorWorkflowState>,
}

impl HydratedHookState {
    pub(super) fn from_skill(skill: &SkillContext) -> Self {
        let mut state = Self::default();
        state.load_run_context();
        state.load_runner_state();
        state.load_author_state(skill);
        state
    }

    fn load_run_context(&mut self) {
        if let Some(run_directory) = &self.run_dir {
            match RunContext::from_run_dir(run_directory) {
                Ok(run_context) => self.run = Some(run_context),
                Err(error) => warn!(%error, "failed to load run context"),
            }
            return;
        }
        match RunContext::from_current() {
            Ok(Some(run_context)) => {
                self.run_dir = Some(run_context.layout.run_dir());
                self.run = Some(run_context);
            }
            Ok(None) => {}
            Err(error) => warn!(%error, "failed to load current run context"),
        }
    }

    fn load_runner_state(&mut self) {
        let run_directory = self
            .run
            .as_ref()
            .map(|run_context| run_context.layout.run_dir())
            .or_else(|| self.run_dir.clone());

        let Some(run_directory) = run_directory else {
            return;
        };

        match runner_workflow::read_runner_state(&run_directory) {
            Ok(runner_state) => self.runner_state = runner_state,
            Err(error) => warn!(%error, "failed to load runner state"),
        }
    }

    fn load_author_state(&mut self, skill: &SkillContext) {
        if !skill.is_author {
            return;
        }
        match read_author_state() {
            Ok(author_state) => self.author_state = author_state,
            Err(error) => warn!(%error, "failed to load author state"),
        }
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
