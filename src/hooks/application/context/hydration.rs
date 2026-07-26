use std::env;
use std::path::PathBuf;

use crate::create::{CreateWorkflowState, read_create_state};
use crate::hooks::protocol::context::{
    NormalizedEvent, NormalizedHookContext, SessionContext, SkillContext,
};
use crate::workspace::canonical_checkout_root;

#[derive(Debug, Clone, Default)]
pub(super) struct HydratedHookState {
    pub(super) create_state: Option<CreateWorkflowState>,
}

impl HydratedHookState {
    pub(super) fn from_skill(skill: &SkillContext) -> Self {
        let mut state = Self::default();
        state.load_create_state(skill);
        state
    }

    fn load_create_state(&mut self, skill: &SkillContext) {
        if skill.is_create() {
            self.read_create_state();
        }
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
    hydrate_normalized_context(normalized)
}

pub(super) fn hydrate_normalized_context(
    mut normalized: NormalizedHookContext,
) -> NormalizedHookContext {
    normalized.session = hydrate_session(normalized.session);
    normalized
}

fn hydrate_session(mut session: SessionContext) -> SessionContext {
    let cwd = session
        .cwd
        .take()
        .unwrap_or_else(|| env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    session.cwd = Some(canonical_checkout_root(&cwd));
    session
}
