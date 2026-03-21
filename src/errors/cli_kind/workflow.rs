use std::borrow::Cow;

use crate::errors::{CliErrorKind, WorkflowError};

impl CliErrorKind {
    #[must_use]
    pub fn invalid_transition(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::Workflow(WorkflowError::invalid_transition(detail))
    }

    #[must_use]
    pub fn workflow_io(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::Workflow(WorkflowError::workflow_io(detail))
    }

    #[must_use]
    pub fn workflow_parse(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::Workflow(WorkflowError::workflow_parse(detail))
    }

    #[must_use]
    pub fn workflow_version(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::Workflow(WorkflowError::workflow_version(detail))
    }

    #[must_use]
    pub fn concurrent_modification(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::Workflow(WorkflowError::concurrent_modification(detail))
    }

    #[must_use]
    pub fn workflow_serialize(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::Workflow(WorkflowError::workflow_serialize(detail))
    }
}
