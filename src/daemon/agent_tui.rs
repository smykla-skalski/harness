#![expect(
    clippy::module_name_repetitions,
    reason = "agent TUI protocol types use an explicit domain prefix"
)]

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::io::{ErrorKind, Read as _, Write as _};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use portable_pty::{Child, CommandBuilder, ExitStatus, MasterPty, PtySize, native_pty_system};
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};

const DEFAULT_ROWS: u16 = 30;
const DEFAULT_COLS: u16 = 120;
#[cfg(test)]
const DEFAULT_WAIT_TIMEOUT: Duration = Duration::from_secs(5);

type Shared<T> = Arc<Mutex<T>>;

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

impl From<AgentTuiSize> for PtySize {
    fn from(size: AgentTuiSize) -> Self {
        Self {
            rows: size.rows,
            cols: size.cols,
            pixel_width: 0,
            pixel_height: 0,
        }
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

/// Fully resolved process spawn request for a managed agent TUI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentTuiSpawnSpec {
    pub profile: AgentTuiLaunchProfile,
    pub project_dir: PathBuf,
    pub env: BTreeMap<String, String>,
    pub size: AgentTuiSize,
}

impl AgentTuiSpawnSpec {
    /// Build a spawn spec and validate the runtime profile and PTY size.
    ///
    /// # Errors
    /// Returns a workflow parse error when the profile or size is invalid.
    pub fn new(
        profile: AgentTuiLaunchProfile,
        project_dir: PathBuf,
        env: BTreeMap<String, String>,
        size: AgentTuiSize,
    ) -> Result<Self, CliError> {
        AgentTuiLaunchProfile::from_argv(&profile.runtime, profile.argv.clone())?;
        Ok(Self {
            profile,
            project_dir,
            env,
            size: size.validate()?,
        })
    }
}

/// PTY backend boundary used by the TUI manager.
pub trait AgentTuiBackend {
    /// Spawn an interactive agent TUI inside a PTY.
    ///
    /// # Errors
    /// Returns a workflow I/O error if PTY allocation or process spawning fails.
    fn spawn(&self, spec: AgentTuiSpawnSpec) -> Result<AgentTuiProcess, CliError>;
}

/// Cross-platform PTY backend powered by `portable-pty`.
#[derive(Debug, Clone, Copy, Default)]
pub struct PortablePtyAgentTuiBackend;

impl AgentTuiBackend for PortablePtyAgentTuiBackend {
    fn spawn(&self, spec: AgentTuiSpawnSpec) -> Result<AgentTuiProcess, CliError> {
        AgentTuiProcess::spawn(spec)
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

/// Live process handle for an agent TUI running inside a PTY.
pub struct AgentTuiProcess {
    master: Shared<Box<dyn MasterPty + Send>>,
    child: Shared<Box<dyn Child + Send + Sync>>,
    writer: Shared<Box<dyn std::io::Write + Send>>,
    transcript: Shared<Vec<u8>>,
    screen: Shared<TerminalScreenParser>,
    reader_thread: Option<JoinHandle<()>>,
}

impl AgentTuiProcess {
    /// Spawn a child process into a PTY and start the output reader thread.
    ///
    /// # Errors
    /// Returns a workflow I/O error on PTY allocation, command spawn, or stream setup failure.
    pub fn spawn(spec: AgentTuiSpawnSpec) -> Result<Self, CliError> {
        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(spec.size.into())
            .map_err(|error| CliErrorKind::workflow_io(format!("open agent TUI PTY: {error}")))?;
        let cmd = command_builder(&spec);
        let child = pair.slave.spawn_command(cmd).map_err(|error| {
            CliErrorKind::workflow_io(format!("spawn agent TUI process: {error}"))
        })?;
        drop(pair.slave);

        let reader = pair.master.try_clone_reader().map_err(|error| {
            CliErrorKind::workflow_io(format!("clone agent TUI PTY reader: {error}"))
        })?;
        let writer = pair.master.take_writer().map_err(|error| {
            CliErrorKind::workflow_io(format!("take agent TUI PTY writer: {error}"))
        })?;

        let transcript = Arc::new(Mutex::new(Vec::new()));
        let screen = Arc::new(Mutex::new(TerminalScreenParser::new(spec.size)));
        let reader_thread =
            spawn_reader_thread(reader, Arc::clone(&transcript), Arc::clone(&screen));

        Ok(Self {
            master: Arc::new(Mutex::new(pair.master)),
            child: Arc::new(Mutex::new(child)),
            writer: Arc::new(Mutex::new(writer)),
            transcript,
            screen,
            reader_thread: Some(reader_thread),
        })
    }

    /// Send structured keyboard input to the PTY.
    ///
    /// # Errors
    /// Returns a workflow parse or I/O error when mapping or writing input fails.
    pub fn send_input(&self, input: &AgentTuiInput) -> Result<(), CliError> {
        self.write_bytes(&input.to_bytes()?)
    }

    /// Send raw bytes to the PTY.
    ///
    /// # Errors
    /// Returns a workflow I/O error when the PTY writer fails.
    pub fn write_bytes(&self, bytes: &[u8]) -> Result<(), CliError> {
        let mut writer = lock(&self.writer, "agent TUI writer")?;
        writer
            .write_all(bytes)
            .and_then(|()| writer.flush())
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("write agent TUI input: {error}")).into()
            })
    }

    /// Resize the PTY and the parsed screen model.
    ///
    /// # Errors
    /// Returns a workflow parse or I/O error when resize fails.
    pub fn resize(&self, size: AgentTuiSize) -> Result<(), CliError> {
        let size = size.validate()?;
        lock(&self.master, "agent TUI PTY master")?
            .resize(size.into())
            .map_err(|error| CliErrorKind::workflow_io(format!("resize agent TUI PTY: {error}")))?;
        lock(&self.screen, "agent TUI screen parser")?.resize(size);
        Ok(())
    }

    /// Return the latest parsed terminal screen.
    ///
    /// # Errors
    /// Returns a workflow I/O error when internal state is poisoned.
    pub fn screen(&self) -> Result<TerminalScreenSnapshot, CliError> {
        Ok(lock(&self.screen, "agent TUI screen parser")?.snapshot())
    }

    /// Return a copy of the raw terminal transcript captured so far.
    ///
    /// # Errors
    /// Returns a workflow I/O error when internal state is poisoned.
    pub fn transcript(&self) -> Result<Vec<u8>, CliError> {
        Ok(lock(&self.transcript, "agent TUI transcript")?.clone())
    }

    /// Poll the child process for exit status without blocking.
    ///
    /// # Errors
    /// Returns a workflow I/O error when process polling fails.
    pub fn try_wait(&self) -> Result<Option<ExitStatus>, CliError> {
        lock(&self.child, "agent TUI child")?
            .try_wait()
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("poll agent TUI process: {error}")).into()
            })
    }

    /// Wait until the child exits or the timeout elapses.
    ///
    /// # Errors
    /// Returns a workflow I/O error when polling fails.
    pub fn wait_timeout(&self, timeout: Duration) -> Result<Option<ExitStatus>, CliError> {
        let started = Instant::now();
        loop {
            if let Some(status) = self.try_wait()? {
                return Ok(Some(status));
            }
            if started.elapsed() >= timeout {
                return Ok(None);
            }
            thread::sleep(Duration::from_millis(20));
        }
    }

    /// Terminate the child process.
    ///
    /// # Errors
    /// Returns a workflow I/O error when process termination fails.
    pub fn kill(&self) -> Result<(), CliError> {
        lock(&self.child, "agent TUI child")?
            .kill()
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("kill agent TUI process: {error}")).into()
            })
    }
}

impl Drop for AgentTuiProcess {
    fn drop(&mut self) {
        if self
            .wait_timeout(Duration::from_millis(10))
            .ok()
            .flatten()
            .is_none()
            && let Ok(mut child) = self.child.lock()
        {
            let _ = child.kill();
        }
        if let Some(reader_thread) = self.reader_thread.take() {
            let _ = reader_thread.join();
        }
    }
}

fn command_builder(spec: &AgentTuiSpawnSpec) -> CommandBuilder {
    let argv = spec
        .profile
        .argv
        .iter()
        .map(OsString::from)
        .collect::<Vec<_>>();
    let mut cmd = CommandBuilder::from_argv(argv);
    cmd.cwd(spec.project_dir.as_os_str());
    cmd.env("TERM", "xterm-256color");
    for (key, value) in &spec.env {
        cmd.env(key, value);
    }
    cmd
}

fn spawn_reader_thread(
    mut reader: Box<dyn std::io::Read + Send>,
    transcript: Shared<Vec<u8>>,
    screen: Shared<TerminalScreenParser>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        let mut buffer = [0_u8; 8192];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(read) => {
                    let bytes = &buffer[..read];
                    if let Ok(mut transcript) = transcript.lock() {
                        transcript.extend_from_slice(bytes);
                    }
                    if let Ok(mut screen) = screen.lock() {
                        screen.process(bytes);
                    }
                }
                Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                Err(_) => break,
            }
        }
    })
}

fn lock<'a, T>(mutex: &'a Mutex<T>, name: &str) -> Result<MutexGuard<'a, T>, CliError> {
    mutex
        .lock()
        .map_err(|error| CliErrorKind::workflow_io(format!("{name} lock poisoned: {error}")).into())
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
    use std::collections::BTreeMap;
    use std::path::PathBuf;
    use std::time::Duration;

    use super::{
        AgentTuiBackend, AgentTuiInput, AgentTuiKey, AgentTuiLaunchProfile, AgentTuiSize,
        AgentTuiSpawnSpec, DEFAULT_WAIT_TIMEOUT, PortablePtyAgentTuiBackend, TerminalScreenParser,
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

    #[test]
    fn portable_pty_backend_round_trips_line_input() {
        let process = spawn_shell("cat");
        process
            .send_input(&AgentTuiInput::Text {
                text: "hello from pty".into(),
            })
            .expect("send text");
        process
            .send_input(&AgentTuiInput::Key {
                key: AgentTuiKey::Enter,
            })
            .expect("send enter");

        wait_until(DEFAULT_WAIT_TIMEOUT, || {
            String::from_utf8_lossy(&process.transcript().expect("transcript"))
                .contains("hello from pty")
        });
    }

    #[test]
    fn portable_pty_backend_preserves_raw_ansi_and_parses_screen_text() {
        let process = spawn_shell("printf '\\033[31mred\\033[0m\\n'");
        let status = process
            .wait_timeout(DEFAULT_WAIT_TIMEOUT)
            .expect("wait")
            .expect("status");
        assert!(status.success());

        let transcript = process.transcript().expect("transcript");
        assert!(
            transcript
                .windows(b"\x1b[31m".len())
                .any(|chunk| chunk == b"\x1b[31m")
        );
        assert!(process.screen().expect("screen").text.contains("red"));
    }

    #[test]
    fn portable_pty_backend_sends_control_c() {
        let process = spawn_shell("sleep 10");
        process
            .send_input(&AgentTuiInput::Control { key: 'c' })
            .expect("send ctrl-c");

        let status = process
            .wait_timeout(DEFAULT_WAIT_TIMEOUT)
            .expect("wait for interrupt");
        assert!(status.is_some(), "process should exit after ctrl-c");
    }

    #[test]
    fn portable_pty_backend_resizes_screen_model() {
        let process = spawn_shell("cat");
        process
            .resize(AgentTuiSize { rows: 9, cols: 33 })
            .expect("resize");

        let screen = process.screen().expect("screen");
        assert_eq!(screen.rows, 9);
        assert_eq!(screen.cols, 33);
    }

    fn spawn_shell(script: &str) -> super::AgentTuiProcess {
        let profile = AgentTuiLaunchProfile::from_argv(
            "codex",
            vec!["sh".to_string(), "-c".to_string(), script.to_string()],
        )
        .expect("profile");
        let spec = AgentTuiSpawnSpec::new(
            profile,
            PathBuf::from("."),
            BTreeMap::new(),
            AgentTuiSize { rows: 5, cols: 40 },
        )
        .expect("spec");
        PortablePtyAgentTuiBackend
            .spawn(spec)
            .expect("spawn pty process")
    }

    fn wait_until(timeout: Duration, mut condition: impl FnMut() -> bool) {
        let start = std::time::Instant::now();
        while start.elapsed() < timeout {
            if condition() {
                return;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(condition(), "condition should become true before timeout");
    }
}
