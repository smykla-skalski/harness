pub(crate) mod application;
pub(crate) mod commands;
mod payload;
mod rules;
mod session;
mod validate;
mod workflow;

pub use application::{CreateApplication, CreatePayloadView};
pub use commands::{
    ApprovalBeginArgs, CreateBeginArgs, CreateResetArgs, CreateSaveArgs, CreateShowArgs,
    CreateValidateArgs,
};
pub use payload::{
    CoverageGroup, CoverageSummary, DraftEditRequest, FileInventory, ProposalGroup,
    ProposalSummary, SchemaFact, SchemaSummary, VariantSignal, VariantSummary,
};
pub use rules::{COPY_GATE, POSTWRITE_GATE, PREWRITE_GATE, ResultKind, SKILL_NAME, Worker};
pub use session::{
    CreateSession, begin_create_session, create_workspace_dir, load_create_session,
    require_create_session, save_create_session,
};
pub use validate::{ManifestTarget, create_validation_repo_root, validate_suite_create_paths};
pub use workflow::{
    ApprovalMode, CreateAnswer, CreateNextAction, CreatePhase, CreateWorkflowState, ReviewGate,
    can_request_gate, can_stop, can_write, create_state_path, next_action, read_create_state,
    suite_create_path_allowed, write_create_state,
};

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
