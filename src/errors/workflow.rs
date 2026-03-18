use std::borrow::Cow;

use super::{define_domain_error_enum, domain_constructor};

define_domain_error_enum! {
    WorkflowError {
        InvalidTransition { detail: Cow<'static, str> } => {
            code: "KSRCLI084",
            msg: "invalid runner state transition: {detail}"
        },
        WorkflowIo { detail: Cow<'static, str> } => {
            code: "WORKFLOW_IO",
            msg: "{detail}"
        },
        WorkflowParse { detail: Cow<'static, str> } => {
            code: "WORKFLOW_PARSE",
            msg: "{detail}"
        },
        WorkflowVersion { detail: Cow<'static, str> } => {
            code: "WORKFLOW_VERSION",
            msg: "unsupported workflow schema version: {detail}"
        },
        ConcurrentModification { detail: Cow<'static, str> } => {
            code: "WORKFLOW_CONCURRENT",
            msg: "workflow state changed concurrently: {detail}"
        },
        WorkflowSerialize { detail: Cow<'static, str> } => {
            code: "WORKFLOW_SERIALIZE",
            msg: "serialization failed: {detail}"
        }
    }
}

impl WorkflowError {
    domain_constructor!(invalid_transition, InvalidTransition, detail);
    domain_constructor!(workflow_io, WorkflowIo, detail);
    domain_constructor!(workflow_parse, WorkflowParse, detail);
    domain_constructor!(workflow_version, WorkflowVersion, detail);
    domain_constructor!(concurrent_modification, ConcurrentModification, detail);
    domain_constructor!(workflow_serialize, WorkflowSerialize, detail);

    #[must_use]
    pub fn hint() -> Option<String> {
        None
    }
}
