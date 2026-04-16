use serde::{Deserialize, Serialize};

use super::model::AgentTuiSize;

/// Parsed terminal screen state exposed to API and CLI consumers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalScreenSnapshot {
    pub rows: u16,
    pub cols: u16,
    pub cursor_row: u16,
    pub cursor_col: u16,
    pub text: String,
}

impl TerminalScreenSnapshot {
    #[must_use]
    pub const fn size(&self) -> AgentTuiSize {
        AgentTuiSize {
            rows: self.rows,
            cols: self.cols,
        }
    }
}

/// Strip leading lines that are empty or contain only whitespace.
///
/// Textual-based TUIs (like Vibe) write spaces to clear screen rows before
/// positioning content mid-screen. `vt100::Screen::contents()` returns those
/// as full-width space lines. Stripping only bare `\n` misses them.
fn strip_leading_blank_lines(text: &str) -> String {
    let mut offset = 0;
    for line in text.split('\n') {
        if line.bytes().any(|byte| !byte.is_ascii_whitespace()) {
            return text[offset..].to_string();
        }
        offset += line.len() + 1;
    }
    String::new()
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
    pub fn state_formatted(&self) -> Vec<u8> {
        self.parser.screen().state_formatted()
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
            text: strip_leading_blank_lines(&screen.contents()),
        }
    }
}
