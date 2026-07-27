use serde::{Deserialize, Serialize};

/// Named keyboard input supported by the headless TUI steering API.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum AgentTuiKey {
    Enter,
    Escape,
    Tab,
    Backspace,
    ArrowUp,
    ArrowDown,
    ArrowRight,
    ArrowLeft,
}

impl AgentTuiKey {
    #[must_use]
    pub const fn bytes(self) -> &'static [u8] {
        match self {
            Self::Enter => b"\r",
            Self::Escape => b"\x1b",
            Self::Tab => b"\t",
            Self::Backspace => b"\x7f",
            Self::ArrowUp => b"\x1b[A",
            Self::ArrowDown => b"\x1b[B",
            Self::ArrowRight => b"\x1b[C",
            Self::ArrowLeft => b"\x1b[D",
        }
    }
}

/// Structured keyboard-like input sent into the PTY master.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum AgentTuiInput {
    Text { text: String },
    Paste { text: String },
    Key { key: AgentTuiKey },
    Control { key: char },
    RawBytesBase64 { data: String },
}

impl AgentTuiInput {
    /// Convert structured input into PTY bytes.
    ///
    /// # Errors
    /// Returns a description of the problem when control-key or base64 input is invalid.
    pub fn to_bytes(&self) -> Result<Vec<u8>, String> {
        match self {
            Self::Text { text } => Ok(text.as_bytes().to_vec()),
            Self::Paste { text } => Ok(bracketed_paste_bytes(text)),
            Self::Key { key } => Ok(key.bytes().to_vec()),
            Self::Control { key } => control_key_bytes(*key),
            Self::RawBytesBase64 { data } => decode_raw_bytes(data),
        }
    }
}

fn bracketed_paste_bytes(text: &str) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(text.len() + 12);
    bytes.extend_from_slice(b"\x1b[200~");
    bytes.extend_from_slice(text.as_bytes());
    bytes.extend_from_slice(b"\x1b[201~");
    bytes
}

fn control_key_bytes(key: char) -> Result<Vec<u8>, String> {
    let normalized = key.to_ascii_uppercase();
    if !normalized.is_ascii_alphabetic() {
        return Err(format!("unsupported control key '{key}'"));
    }
    let byte = u8::try_from(normalized)
        .map_err(|error| format!("invalid control key '{key}': {error}"))?;
    Ok(vec![byte - b'A' + 1])
}

fn decode_raw_bytes(data: &str) -> Result<Vec<u8>, String> {
    use base64::Engine as _;
    use base64::engine::general_purpose::STANDARD;

    STANDARD
        .decode(data)
        .map_err(|error| format!("invalid raw bytes base64: {error}"))
}

/// One timed input step replayed into an active terminal agent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct AgentTuiInputSequenceStep {
    pub delay_before_ms: u64,
    pub input: AgentTuiInput,
}

/// Ordered keyboard-like input replayed into an active terminal agent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct AgentTuiInputSequence {
    pub steps: Vec<AgentTuiInputSequenceStep>,
}

impl AgentTuiInputSequence {
    /// Validate a timed input sequence before it is queued for replay.
    ///
    /// # Errors
    /// Returns a description of the problem when the sequence is empty, the
    /// first step is delayed, or any nested input is invalid.
    pub fn validate(&self) -> Result<(), String> {
        let Some(first) = self.steps.first() else {
            return Err("terminal agent input sequence requires at least one step".to_string());
        };
        if first.delay_before_ms != 0 {
            return Err(
                "terminal agent input sequence must start with delay_before_ms = 0".to_string(),
            );
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
    /// Returns a description of the problem when the sequence is invalid.
    pub fn from_sequence(sequence: AgentTuiInputSequence) -> Result<Self, String> {
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
    /// Returns a description of the problem when the request is empty,
    /// ambiguous, or carries an invalid input payload.
    pub fn validate(&self) -> Result<(), String> {
        match (&self.input, &self.sequence) {
            (Some(input), None) => {
                let _ = input.to_bytes()?;
                Ok(())
            }
            (None, Some(sequence)) => sequence.validate(),
            _ => Err(
                "terminal agent input request requires exactly one of 'input' or 'sequence'"
                    .to_string(),
            ),
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
        request.validate()?;
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

/// Documented wire shape of [`AgentTuiInputRequest`], which hand-rolls its serde
/// through `RawAgentTuiInputRequest`. Exactly one of `input` or `sequence` is
/// accepted; the validation lives in the handler, so the schema documents both
/// as optional.
// Documentation-only: the daemon names it from a `utoipa::path` annotation,
// but crates that include this file without serving HTTP never reach it.
#[allow(dead_code)]
#[derive(serde::Serialize, serde::Deserialize, utoipa::ToSchema)]
pub struct AgentTuiInputRequestSchema {
    #[serde(default)]
    pub input: Option<AgentTuiInput>,
    #[serde(default)]
    pub sequence: Option<AgentTuiInputSequence>,
}
