use crate::hook_payloads::HookEvent;

/// Outcome of a hook evaluation for debug logging.
#[derive(Debug)]
pub struct HookOutcome {
    pub exit_code: i32,
    pub outcome: String,
    pub message: Option<String>,
    pub gate: Option<String>,
}

impl HookOutcome {
    /// Log the outcome and return the exit code.
    pub fn log_and_exit(self, _hook_name: &str, _event: &HookEvent) -> i32 {
        self.exit_code
    }
}

#[cfg(test)]
mod tests {}
