//! Per-session state for the OpenRouter ACP shim.
//!
//! The shim is a single child process that may host multiple ACP sessions
//! concurrently (the daemon dispatches sessions to a single instance). Each
//! `SessionId` carries an isolated `ChatMessage` history, a project working
//! directory, the chosen model, and a cancellation flag the prompt loop polls
//! between SSE chunks.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use agent_client_protocol::schema::v1::SessionId;
use tokio::sync::Mutex;

use crate::openrouter::ChatMessage;

/// Per-session state held in `SessionStore`.
#[derive(Debug)]
pub struct SessionState {
    pub project_dir: PathBuf,
    pub model: String,
    pub reasoning_effort: Option<String>,
    pub history: Vec<ChatMessage>,
    /// Set to `true` by `session/cancel`. The prompt loop polls this between
    /// SSE chunks and tool calls and returns `StopReason::Cancelled`.
    pub cancel_flag: Arc<AtomicBool>,
}

impl SessionState {
    pub fn new(project_dir: PathBuf, model: String) -> Self {
        Self {
            project_dir,
            model,
            reasoning_effort: None,
            history: Vec::new(),
            cancel_flag: Arc::new(AtomicBool::new(false)),
        }
    }
}

/// Thread-safe map of `SessionId → SessionState`. Cheap to clone (shared
/// `Arc<Mutex<…>>`).
#[derive(Debug, Clone, Default)]
pub struct SessionStore {
    inner: Arc<Mutex<HashMap<SessionId, SessionState>>>,
}

impl SessionStore {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Insert a fresh session keyed by `session_id`.
    pub async fn insert(&self, session_id: SessionId, state: SessionState) {
        self.inner.lock().await.insert(session_id, state);
    }

    /// Snapshot the session's history, project dir, model, reasoning effort,
    /// and cancel-flag handle. Returns `None` if no such session exists.
    pub async fn snapshot(&self, session_id: &SessionId) -> Option<SessionSnapshot> {
        self.inner
            .lock()
            .await
            .get(session_id)
            .map(|state| SessionSnapshot {
                project_dir: state.project_dir.clone(),
                model: state.model.clone(),
                reasoning_effort: state.reasoning_effort.clone(),
                history: state.history.clone(),
                cancel_flag: state.cancel_flag.clone(),
            })
    }

    /// Append `messages` to the named session's history. Silently drops the
    /// extension when the session has been forgotten (e.g., racing cancel).
    pub async fn extend_history(&self, session_id: &SessionId, messages: Vec<ChatMessage>) {
        if let Some(state) = self.inner.lock().await.get_mut(session_id) {
            state.history.extend(messages);
        }
    }

    /// Update the session's model. Returns `true` when the session existed.
    pub async fn set_model(&self, session_id: &SessionId, model: &str) -> bool {
        if let Some(state) = self.inner.lock().await.get_mut(session_id) {
            state.model = model.to_owned();
            true
        } else {
            false
        }
    }

    /// Mark the session for cancellation. The prompt loop polls the flag and
    /// returns `StopReason::Cancelled`. Returns `true` when the session
    /// existed.
    pub async fn cancel(&self, session_id: &SessionId) -> bool {
        if let Some(state) = self.inner.lock().await.get(session_id) {
            state.cancel_flag.store(true, Ordering::SeqCst);
            true
        } else {
            false
        }
    }

    /// Reset the cancellation flag before starting a new turn so a previously
    /// cancelled session can be prompted again without leaking the stale flag.
    pub async fn reset_cancel(&self, session_id: &SessionId) {
        if let Some(state) = self.inner.lock().await.get(session_id) {
            state.cancel_flag.store(false, Ordering::SeqCst);
        }
    }
}

/// Read-only view returned by [`SessionStore::snapshot`].
#[derive(Debug, Clone)]
pub struct SessionSnapshot {
    pub project_dir: PathBuf,
    pub model: String,
    pub reasoning_effort: Option<String>,
    pub history: Vec<ChatMessage>,
    pub cancel_flag: Arc<AtomicBool>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(name: &str) -> SessionId {
        SessionId::new(name.to_owned())
    }

    #[tokio::test]
    async fn insert_then_snapshot_returns_state() {
        let store = SessionStore::new();
        let id = session("openrouter-1");
        store
            .insert(
                id.clone(),
                SessionState::new(PathBuf::from("/tmp/proj"), "anthropic/claude".to_owned()),
            )
            .await;
        let snap = store.snapshot(&id).await.expect("snapshot");
        assert_eq!(snap.project_dir, PathBuf::from("/tmp/proj"));
        assert_eq!(snap.model, "anthropic/claude");
        assert!(snap.history.is_empty());
        assert!(!snap.cancel_flag.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn cancel_sets_flag_on_existing_session_only() {
        let store = SessionStore::new();
        let id = session("openrouter-2");
        assert!(!store.cancel(&id).await);
        store
            .insert(
                id.clone(),
                SessionState::new(PathBuf::from("/tmp"), "m".to_owned()),
            )
            .await;
        assert!(store.cancel(&id).await);
        let snap = store.snapshot(&id).await.expect("snapshot");
        assert!(snap.cancel_flag.load(Ordering::SeqCst));
        store.reset_cancel(&id).await;
        let snap = store.snapshot(&id).await.expect("snapshot");
        assert!(!snap.cancel_flag.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn set_model_updates_existing_session_only() {
        let store = SessionStore::new();
        let id = session("openrouter-4");
        assert!(!store.set_model(&id, "openai/gpt-5.5").await);
        store
            .insert(
                id.clone(),
                SessionState::new(PathBuf::from("/tmp"), "m".to_owned()),
            )
            .await;
        assert!(store.set_model(&id, "openai/gpt-5.5").await);
        let snap = store.snapshot(&id).await.expect("snapshot");
        assert_eq!(snap.model, "openai/gpt-5.5");
    }

    #[tokio::test]
    async fn extend_history_appends_in_order() {
        use crate::openrouter::ChatRole;
        let store = SessionStore::new();
        let id = session("openrouter-3");
        store
            .insert(
                id.clone(),
                SessionState::new(PathBuf::from("/tmp"), "m".to_owned()),
            )
            .await;
        store
            .extend_history(
                &id,
                vec![ChatMessage {
                    role: ChatRole::User,
                    content: Some("first".to_owned()),
                    tool_call_id: None,
                    name: None,
                    tool_calls: Vec::new(),
                }],
            )
            .await;
        store
            .extend_history(
                &id,
                vec![ChatMessage {
                    role: ChatRole::Assistant,
                    content: Some("reply".to_owned()),
                    tool_call_id: None,
                    name: None,
                    tool_calls: Vec::new(),
                }],
            )
            .await;
        let snap = store.snapshot(&id).await.expect("snapshot");
        assert_eq!(snap.history.len(), 2);
        assert_eq!(snap.history[0].content.as_deref(), Some("first"));
        assert_eq!(snap.history[1].content.as_deref(), Some("reply"));
    }
}
