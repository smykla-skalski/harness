use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};

const DEFAULT_ROWS: u16 = 30;
const DEFAULT_COLS: u16 = 120;

/// Terminal dimensions used when spawning or resizing an agent TUI.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiSize {
    pub rows: u16,
    pub cols: u16,
}

impl Default for AgentTuiSize {
    fn default() -> Self {
        Self {
            rows: DEFAULT_ROWS,
            cols: DEFAULT_COLS,
        }
    }
}

impl AgentTuiSize {
    /// Validate that the PTY has a usable non-zero size.
    ///
    /// # Errors
    /// Returns a workflow parse error when either dimension is zero.
    pub fn validate(self) -> Result<Self, CliError> {
        if self.rows == 0 || self.cols == 0 {
            return Err(CliErrorKind::workflow_parse(
                "agent TUI rows and cols must be greater than zero",
            )
            .into());
        }
        Ok(self)
    }
}

/// Runtime-specific command profile for launching an interactive agent CLI.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiLaunchProfile {
    pub runtime: String,
    pub argv: Vec<String>,
}

impl AgentTuiLaunchProfile {
    /// Resolve the default launch profile for a supported runtime.
    ///
    /// # Errors
    /// Returns a workflow parse error when the runtime is unknown.
    pub fn for_runtime(runtime: &str) -> Result<Self, CliError> {
        let runtime = runtime.trim();
        let program = match runtime {
            "codex" => "codex",
            "claude" => "claude",
            "gemini" => "gemini",
            "opencode" => "opencode",
            "copilot" => "copilot",
            _ => {
                return Err(CliErrorKind::workflow_parse(format!(
                    "unsupported agent TUI runtime '{runtime}'"
                ))
                .into());
            }
        };
        Ok(Self {
            runtime: runtime.to_string(),
            argv: vec![program.to_string()],
        })
    }

    /// Build an explicit launch profile from a structured argv override.
    ///
    /// # Errors
    /// Returns a workflow parse error when the runtime or argv is empty.
    pub fn from_argv(runtime: &str, argv: Vec<String>) -> Result<Self, CliError> {
        let runtime = runtime.trim();
        if runtime.is_empty() {
            return Err(CliErrorKind::workflow_parse("agent TUI runtime cannot be empty").into());
        }
        let Some(program) = argv.first().map(|value| value.trim()) else {
            return Err(CliErrorKind::workflow_parse("agent TUI argv cannot be empty").into());
        };
        if program.is_empty() {
            return Err(CliErrorKind::workflow_parse("agent TUI argv[0] cannot be empty").into());
        }
        Ok(Self {
            runtime: runtime.to_string(),
            argv,
        })
    }
}

/// Named keyboard input supported by the headless TUI steering API.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
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
    /// Returns a workflow parse error when control-key or base64 input is invalid.
    pub fn to_bytes(&self) -> Result<Vec<u8>, CliError> {
        match self {
            Self::Text { text } => Ok(text.as_bytes().to_vec()),
            Self::Paste { text } => Ok(bracketed_paste_bytes(text)),
            Self::Key { key } => Ok(key.bytes().to_vec()),
            Self::Control { key } => control_key_bytes(*key),
            Self::RawBytesBase64 { data } => decode_raw_bytes(data),
        }
    }
}

/// Parsed terminal screen state exposed to API and CLI consumers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalScreenSnapshot {
    pub rows: u16,
    pub cols: u16,
    pub cursor_row: u16,
    pub cursor_col: u16,
    pub text: String,
}

/// Incremental terminal parser that keeps a `vt100` screen model.
pub struct TerminalScreenParser {
    parser: vt100::Parser,
}

impl TerminalScreenParser {
    #[must_use]
    pub fn new(size: AgentTuiSize) -> Self {
        Self {
            parser: vt100::Parser::new(size.rows, size.cols, 0),
        }
    }

    pub fn process(&mut self, bytes: &[u8]) {
        self.parser.process(bytes);
    }

    pub fn resize(&mut self, size: AgentTuiSize) {
        self.parser.screen_mut().set_size(size.rows, size.cols);
    }

    #[must_use]
    pub fn snapshot(&self) -> TerminalScreenSnapshot {
        let screen = self.parser.screen();
        let (rows, cols) = screen.size();
        let (cursor_row, cursor_col) = screen.cursor_position();
        TerminalScreenSnapshot {
            rows,
            cols,
            cursor_row,
            cursor_col,
            text: screen.contents(),
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

fn control_key_bytes(key: char) -> Result<Vec<u8>, CliError> {
    let normalized = key.to_ascii_uppercase();
    if !normalized.is_ascii_alphabetic() {
        return Err(
            CliErrorKind::workflow_parse(format!("unsupported control key '{key}'")).into(),
        );
    }
    let byte = u8::try_from(normalized).map_err(|error| {
        CliErrorKind::workflow_parse(format!("invalid control key '{key}': {error}"))
    })?;
    Ok(vec![byte - b'A' + 1])
}

fn decode_raw_bytes(data: &str) -> Result<Vec<u8>, CliError> {
    use base64::Engine as _;
    use base64::engine::general_purpose::STANDARD;

    STANDARD.decode(data).map_err(|error| {
        CliErrorKind::workflow_parse(format!("invalid raw bytes base64: {error}")).into()
    })
}

#[cfg(test)]
mod tests {
    use super::{
        AgentTuiInput, AgentTuiKey, AgentTuiLaunchProfile, AgentTuiSize, TerminalScreenParser,
    };

    #[test]
    fn launch_profiles_cover_all_supported_runtimes() {
        let cases = [
            ("codex", "codex"),
            ("claude", "claude"),
            ("gemini", "gemini"),
            ("opencode", "opencode"),
            ("copilot", "copilot"),
        ];

        for (runtime, program) in cases {
            let profile = AgentTuiLaunchProfile::for_runtime(runtime).expect("profile");
            assert_eq!(profile.runtime, runtime);
            assert_eq!(profile.argv, vec![program.to_string()]);
        }
    }

    #[test]
    fn launch_profile_rejects_unknown_runtime() {
        let error = AgentTuiLaunchProfile::for_runtime("unknown").expect_err("runtime should fail");

        assert!(
            error
                .to_string()
                .contains("unsupported agent TUI runtime 'unknown'")
        );
    }

    #[test]
    fn launch_profile_override_rejects_empty_argv() {
        let error =
            AgentTuiLaunchProfile::from_argv("codex", Vec::new()).expect_err("argv should fail");

        assert!(error.to_string().contains("agent TUI argv cannot be empty"));
    }

    #[test]
    fn launch_profile_override_rejects_empty_program() {
        let error = AgentTuiLaunchProfile::from_argv("codex", vec![" ".to_string()])
            .expect_err("program should fail");

        assert!(
            error
                .to_string()
                .contains("agent TUI argv[0] cannot be empty")
        );
    }

    #[test]
    fn structured_input_maps_to_terminal_bytes() {
        assert_eq!(
            AgentTuiInput::Text {
                text: "hello".into()
            }
            .to_bytes()
            .expect("text bytes"),
            b"hello"
        );
        assert_eq!(
            AgentTuiInput::Key {
                key: AgentTuiKey::Enter
            }
            .to_bytes()
            .expect("enter bytes"),
            b"\r"
        );
        assert_eq!(
            AgentTuiInput::Key {
                key: AgentTuiKey::ArrowUp
            }
            .to_bytes()
            .expect("arrow bytes"),
            b"\x1b[A"
        );
        assert_eq!(
            AgentTuiInput::Control { key: 'c' }
                .to_bytes()
                .expect("control bytes"),
            b"\x03"
        );
    }

    #[test]
    fn paste_uses_bracketed_paste_sequences() {
        let bytes = AgentTuiInput::Paste {
            text: "multi\nline".into(),
        }
        .to_bytes()
        .expect("paste bytes");

        assert_eq!(bytes, b"\x1b[200~multi\nline\x1b[201~");
    }

    #[test]
    fn raw_bytes_decode_from_base64() {
        let bytes = AgentTuiInput::RawBytesBase64 {
            data: "AAEC".into(),
        }
        .to_bytes()
        .expect("raw bytes");

        assert_eq!(bytes, vec![0, 1, 2]);
    }

    #[test]
    fn size_rejects_zero_dimensions() {
        let error = AgentTuiSize { rows: 0, cols: 120 }
            .validate()
            .expect_err("size should fail");

        assert!(
            error
                .to_string()
                .contains("agent TUI rows and cols must be greater than zero")
        );
    }

    #[test]
    fn terminal_parser_preserves_visible_text_and_resize() {
        let mut parser = TerminalScreenParser::new(AgentTuiSize { rows: 4, cols: 20 });
        parser.process(b"hello\x1b[2;1Hworld");
        let snapshot = parser.snapshot();
        assert_eq!(snapshot.rows, 4);
        assert_eq!(snapshot.cols, 20);
        assert!(snapshot.text.contains("hello"));
        assert!(snapshot.text.contains("world"));

        parser.resize(AgentTuiSize { rows: 10, cols: 40 });
        let resized = parser.snapshot();
        assert_eq!(resized.rows, 10);
        assert_eq!(resized.cols, 40);
    }
}
