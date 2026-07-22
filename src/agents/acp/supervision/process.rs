//! What a supervisor needs to know about the process behind a session.
//!
//! A local agent is a child the daemon spawned, with a pid and a process group
//! the watchdog reaps. Isolating that here is the seam a remote transport later
//! fills with a process it never owned - the supervisor's deadlines, watchdog,
//! and pending-request accounting are all indifferent to how the agent runs.

use std::process::Child;

#[derive(Debug, Clone, Copy)]
pub struct SupervisedProcess {
    pid: u32,
    process_group: i32,
}

impl SupervisedProcess {
    /// The process the daemon spawned as `child`.
    #[must_use]
    pub fn from_child(child: &Child) -> Self {
        #[cfg(unix)]
        let process_group = child.id().cast_signed();
        #[cfg(not(unix))]
        let process_group = child.id() as i32;
        Self {
            pid: child.id(),
            process_group,
        }
    }

    /// A process identified by explicit ids rather than a live `Child` handle.
    #[must_use]
    pub const fn new(pid: u32, process_group: i32) -> Self {
        Self { pid, process_group }
    }

    /// A remote agent the daemon connects to but never spawned. The pid and
    /// process group are zero: there is no local process to report or reap, and
    /// the childless session never calls the reaper.
    #[must_use]
    pub const fn remote() -> Self {
        Self {
            pid: 0,
            process_group: 0,
        }
    }

    #[must_use]
    pub const fn pid(&self) -> u32 {
        self.pid
    }

    #[must_use]
    pub const fn process_group(&self) -> i32 {
        self.process_group
    }
}
