pub(crate) mod application;
pub(crate) mod commands;
mod payload;
mod rules;
mod session;
mod validate;
mod workflow;

pub use application::{AuthoringApplication, AuthoringPayloadView};
pub use commands::{
    ApprovalBeginArgs, AuthoringBeginArgs, AuthoringResetArgs, AuthoringSaveArgs,
    AuthoringShowArgs, AuthoringValidateArgs,
};
pub use payload::{
    CoverageGroup, CoverageSummary, DraftEditRequest, FileInventory, ProposalGroup,
    ProposalSummary, SchemaFact, SchemaSummary, VariantSignal, VariantSummary,
};
pub use rules::{COPY_GATE, POSTWRITE_GATE, PREWRITE_GATE, ResultKind, SKILL_NAME, Worker};
pub use session::{
    AuthoringSession, authoring_workspace_dir, begin_authoring_session, load_authoring_session,
    require_authoring_session, save_authoring_session,
};
pub use validate::{ManifestTarget, authoring_validation_repo_root, validate_suite_author_paths};
pub use workflow::{
    ApprovalMode, AuthorAnswer, AuthorNextAction, AuthorPhase, AuthorWorkflowState, ReviewGate,
    author_state_path, can_request_gate, can_stop, can_write, next_action, read_author_state,
    suite_author_path_allowed, write_author_state,
};

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
