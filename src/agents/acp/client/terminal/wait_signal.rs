//! Wakeup signal shared by a terminal's readers, its exit monitor, and the
//! handlers parked on `terminal/wait_for_exit`.

use std::sync::{Condvar, Mutex};
use std::time::Duration;

use agent_client_protocol::schema::v1::TerminalExitStatus;

use crate::agents::acp::client::ClientCallCancel;

#[derive(Clone, Copy)]
pub(in crate::agents::acp::client) struct TerminalWaitSnapshot {
    pub(super) generation: u64,
    pub(super) reader_closed: bool,
}

pub(in crate::agents::acp::client) enum TerminalLifecycleWait {
    TimedOut,
    Cancelled,
    Exit(TerminalExitStatus),
    LifecycleError(String),
}

struct TerminalWaitState {
    generation: u64,
    reader_closed: bool,
    exit_status: Option<TerminalExitStatus>,
    lifecycle_error: Option<String>,
}

pub(in crate::agents::acp::client) struct TerminalWaitSignal {
    state: Mutex<TerminalWaitState>,
    condvar: Condvar,
}

impl TerminalWaitSignal {
    pub(super) fn new() -> Self {
        Self {
            state: Mutex::new(TerminalWaitState {
                generation: 0,
                reader_closed: false,
                exit_status: None,
                lifecycle_error: None,
            }),
            condvar: Condvar::new(),
        }
    }

    pub(super) fn snapshot(&self) -> TerminalWaitSnapshot {
        let state = self.state.lock().unwrap();
        TerminalWaitSnapshot {
            generation: state.generation,
            reader_closed: state.reader_closed,
        }
    }

    pub(super) fn wait_for_change(
        &self,
        snapshot: TerminalWaitSnapshot,
        timeout: Duration,
    ) -> TerminalWaitSnapshot {
        let state = self.state.lock().unwrap();
        let state = self
            .condvar
            .wait_timeout_while(state, timeout, |state| {
                state.generation == snapshot.generation
                    && state.reader_closed == snapshot.reader_closed
            })
            .unwrap()
            .0;
        TerminalWaitSnapshot {
            generation: state.generation,
            reader_closed: state.reader_closed,
        }
    }

    /// Park until the terminal exits, the lifecycle fails, `timeout` elapses,
    /// or `cancel` is tripped. The cancel token is part of the condvar
    /// predicate, and its wake callback pokes this condvar, so a cancel from
    /// another thread unblocks the wait instead of leaving it parked until the
    /// wall-clock cap.
    pub(super) fn wait_for_exit_or_error(
        &self,
        timeout: Duration,
        cancel: &ClientCallCancel,
    ) -> TerminalLifecycleWait {
        let state = self.state.lock().unwrap();
        let state = self
            .condvar
            .wait_timeout_while(state, timeout, |state| {
                state.exit_status.is_none()
                    && state.lifecycle_error.is_none()
                    && !cancel.is_cancelled()
            })
            .unwrap()
            .0;
        if let Some(exit_status) = state.exit_status.clone() {
            TerminalLifecycleWait::Exit(exit_status)
        } else if let Some(error) = state.lifecycle_error.clone() {
            TerminalLifecycleWait::LifecycleError(error)
        } else if cancel.is_cancelled() {
            TerminalLifecycleWait::Cancelled
        } else {
            TerminalLifecycleWait::TimedOut
        }
    }

    /// Wake every waiter parked on this signal without changing terminal
    /// state, so a cancelled waiter re-evaluates its predicate.
    pub(super) fn wake_waiters(&self) {
        let _state = self.state.lock().unwrap();
        self.condvar.notify_all();
    }

    pub(super) fn note_output_updated(&self) {
        let mut state = self.state.lock().unwrap();
        state.generation += 1;
        self.condvar.notify_all();
    }

    pub(super) fn note_reader_closed(&self) {
        let mut state = self.state.lock().unwrap();
        state.reader_closed = true;
        state.generation += 1;
        self.condvar.notify_all();
    }

    pub(super) fn finish_exit(&self, exit_status: TerminalExitStatus) {
        let mut state = self.state.lock().unwrap();
        state.exit_status = Some(exit_status);
        state.generation += 1;
        self.condvar.notify_all();
    }

    pub(super) fn fail_poll(&self, error: String) {
        let mut state = self.state.lock().unwrap();
        state.lifecycle_error = Some(error);
        state.generation += 1;
        self.condvar.notify_all();
    }

    pub(super) fn exit_status(&self) -> Option<TerminalExitStatus> {
        self.state.lock().unwrap().exit_status.clone()
    }

    pub(super) fn lifecycle_error(&self) -> Option<String> {
        self.state.lock().unwrap().lifecycle_error.clone()
    }
}
