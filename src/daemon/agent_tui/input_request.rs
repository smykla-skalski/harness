use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};

use super::input::AgentTuiInput;

/// One timed input step replayed into an active terminal agent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiInputSequenceStep {
    pub delay_before_ms: u64,
    pub input: AgentTuiInput,
}

/// Ordered keyboard-like input replayed into an active terminal agent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiInputSequence {
    pub steps: Vec<AgentTuiInputSequenceStep>,
}

impl AgentTuiInputSequence {
    /// Validate a timed input sequence before it is queued for replay.
    ///
    /// # Errors
    /// Returns a workflow parse error when the sequence is empty, the first
    /// step is delayed, or any nested input is invalid.
    pub fn validate(&self) -> Result<(), CliError> {
        let Some(first) = self.steps.first() else {
            return Err(CliErrorKind::workflow_parse(
                "terminal agent input sequence requires at least one step",
            )
            .into());
        };
        if first.delay_before_ms != 0 {
            return Err(CliErrorKind::workflow_parse(
                "terminal agent input sequence must start with delay_before_ms = 0",
            )
            .into());
        }
        for step in &self.steps {
            let _ = step.input.to_bytes()?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct RawAgentTuiInputRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    input: Option<AgentTuiInput>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sequence: Option<AgentTuiInputSequence>,
}

/// Request body for sending keyboard-like input into an active terminal agent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "RawAgentTuiInputRequest", into = "RawAgentTuiInputRequest")]
pub struct AgentTuiInputRequest {
    input: Option<AgentTuiInput>,
    sequence: Option<AgentTuiInputSequence>,
}

impl AgentTuiInputRequest {
    #[must_use]
    pub const fn from_input(input: AgentTuiInput) -> Self {
        Self {
            input: Some(input),
            sequence: None,
        }
    }

    /// Build a timed input request for one active TUI.
    ///
    /// # Errors
    /// Returns a workflow parse error when the sequence is invalid.
    pub fn from_sequence(sequence: AgentTuiInputSequence) -> Result<Self, CliError> {
        sequence.validate()?;
        Ok(Self {
            input: None,
            sequence: Some(sequence),
        })
    }

    #[must_use]
    pub const fn input(&self) -> Option<&AgentTuiInput> {
        self.input.as_ref()
    }

    #[must_use]
    pub const fn sequence(&self) -> Option<&AgentTuiInputSequence> {
        self.sequence.as_ref()
    }

    /// Validate that the request carries exactly one supported input payload.
    ///
    /// # Errors
    /// Returns a workflow parse error when the request is empty, ambiguous, or
    /// carries an invalid input payload.
    pub fn validate(&self) -> Result<(), CliError> {
        match (&self.input, &self.sequence) {
            (Some(input), None) => {
                let _ = input.to_bytes()?;
                Ok(())
            }
            (None, Some(sequence)) => sequence.validate(),
            _ => Err(CliErrorKind::workflow_parse(
                "terminal agent input request requires exactly one of 'input' or 'sequence'",
            )
            .into()),
        }
    }
}

impl TryFrom<RawAgentTuiInputRequest> for AgentTuiInputRequest {
    type Error = String;

    fn try_from(raw: RawAgentTuiInputRequest) -> Result<Self, Self::Error> {
        let request = Self {
            input: raw.input,
            sequence: raw.sequence,
        };
        request.validate().map_err(|error| error.to_string())?;
        Ok(request)
    }
}

impl From<AgentTuiInputRequest> for RawAgentTuiInputRequest {
    fn from(request: AgentTuiInputRequest) -> Self {
        Self {
            input: request.input,
            sequence: request.sequence,
        }
    }
}
