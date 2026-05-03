use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct PromptOwner {
    acp_id: String,
    session_id: String,
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct PromptBusy {
    owner: PromptOwner,
}

#[derive(Clone, Default)]
pub(super) struct PromptGate {
    owner: Arc<Mutex<Option<PromptOwner>>>,
}

pub(super) struct PromptLease {
    gate: PromptGate,
    owner: PromptOwner,
}

impl PromptOwner {
    pub(super) fn new(acp_id: &str, session_id: &str) -> Self {
        Self {
            acp_id: acp_id.to_string(),
            session_id: session_id.to_string(),
        }
    }
}

impl PromptBusy {
    pub(super) fn message(&self) -> String {
        format!(
            "prompt_busy: ACP prompt is already owned by logical session '{}' ({})",
            self.owner.session_id, self.owner.acp_id
        )
    }
}

impl PromptGate {
    pub(super) fn acquire(&self, owner: PromptOwner) -> Result<PromptLease, PromptBusy> {
        let mut guard = recover_lock(&self.owner);
        if let Some(existing) = guard.clone() {
            return Err(PromptBusy { owner: existing });
        }
        *guard = Some(owner.clone());
        Ok(PromptLease {
            gate: self.clone(),
            owner,
        })
    }

    fn release(&self, owner: &PromptOwner) {
        let mut guard = recover_lock(&self.owner);
        if guard.as_ref() == Some(owner) {
            *guard = None;
        }
    }
}

fn recover_lock(owner: &Mutex<Option<PromptOwner>>) -> MutexGuard<'_, Option<PromptOwner>> {
    match owner.lock() {
        Ok(guard) => guard,
        Err(error) => recover_poisoned_lock(error),
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn recover_poisoned_lock(
    error: PoisonError<MutexGuard<'_, Option<PromptOwner>>>,
) -> MutexGuard<'_, Option<PromptOwner>> {
    tracing::warn!(%error, "recovering poisoned ACP prompt gate lock");
    error.into_inner()
}

impl Drop for PromptLease {
    fn drop(&mut self) {
        self.gate.release(&self.owner);
    }
}

pub(super) fn prompt_text(prompt: Option<&str>) -> Option<String> {
    prompt
        .map(str::trim)
        .filter(|prompt| !prompt.is_empty())
        .map(ToOwned::to_owned)
}
