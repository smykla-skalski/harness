//! Samples gix's clone progress tree and turns it into
//! [`WorkingCopyProgress::Advanced`] events.
//!
//! gix reports progress by mutating a `prodash` tree rather than by calling
//! back, so nothing is emitted unless someone reads the tree. This module owns
//! that reader: a thread wakes on a fixed interval, snapshots the tree, and
//! reports the most specific task that carries a count.
//!
//! The sampler emits on every tick even when the counts have not moved. A
//! consumer telling a stalled clone from an advancing one needs to see that
//! time passed without the numbers changing, which it cannot infer from
//! silence - silence also means finished.

use std::sync::atomic::Ordering;
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use gix::progress::prodash::progress::{Key, State};
use gix::progress::{Task, tree};

use super::progress::{WorkingCopyProgress, WorkingCopyProgressSink};

/// How often the tree is sampled. Fast enough that a stalled clone is obvious
/// within a couple of seconds, slow enough to stay negligible on the broadcast
/// channel.
const SAMPLE_INTERVAL: Duration = Duration::from_millis(500);

/// Owns the progress tree handed to gix and the thread that samples it.
///
/// Dropping the reporter stops the sampler, so an early return cannot leak the
/// thread by skipping [`Self::finish`].
pub(super) struct CloneProgressReporter {
    root: Arc<tree::Root>,
    stop: Arc<StopSignal>,
    sampler: Option<JoinHandle<()>>,
}

impl CloneProgressReporter {
    pub(super) fn start(sink: Arc<dyn WorkingCopyProgressSink>, repo_full_name: String) -> Self {
        let root = tree::Root::new();
        let stop = Arc::new(StopSignal::default());
        let sampler = thread::spawn({
            let root = Arc::clone(&root);
            let stop = Arc::clone(&stop);
            move || sample_until_stopped(&root, &stop, sink.as_ref(), &repo_full_name)
        });
        Self {
            root,
            stop,
            sampler: Some(sampler),
        }
    }

    /// The progress handle to hand to gix, which nests its own phases beneath
    /// it.
    pub(super) fn progress(&self) -> tree::Item {
        self.root.add_child("clone")
    }

    /// Stop sampling and wait for the thread, so no `Advanced` event can land
    /// after the terminal event the caller is about to report.
    pub(super) fn finish(mut self) {
        self.stop_and_join();
    }

    fn stop_and_join(&mut self) {
        self.stop.stop();
        if let Some(sampler) = self.sampler.take() {
            let _ = sampler.join();
        }
    }
}

/// The sampler's stop flag, waited on rather than polled.
///
/// A plain flag plus `thread::sleep` would make every caller absorb whatever
/// remained of the current interval before its terminal event, adding up to
/// [`SAMPLE_INTERVAL`] to each clone. Waiting on a condvar lets `stop` wake the
/// sampler at once, and the mutex around the flag is the same handoff that
/// publishes it.
#[derive(Default)]
struct StopSignal {
    stopped: Mutex<bool>,
    changed: Condvar,
}

impl StopSignal {
    fn stop(&self) {
        let mut stopped = self.stopped.lock().unwrap_or_else(PoisonError::into_inner);
        *stopped = true;
        self.changed.notify_all();
    }

    /// Wait up to `timeout` for a stop request, reporting whether one arrived.
    fn wait_for_stop(&self, timeout: Duration) -> bool {
        let stopped = self.stopped.lock().unwrap_or_else(PoisonError::into_inner);
        if *stopped {
            return true;
        }
        let (stopped, _) = self
            .changed
            .wait_timeout(stopped, timeout)
            .unwrap_or_else(PoisonError::into_inner);
        *stopped
    }
}

impl Drop for CloneProgressReporter {
    fn drop(&mut self) {
        self.stop_and_join();
    }
}

fn sample_until_stopped(
    root: &tree::Root,
    stop: &StopSignal,
    sink: &dyn WorkingCopyProgressSink,
    repo_full_name: &str,
) {
    let mut tasks = Vec::new();
    while !stop.wait_for_stop(SAMPLE_INTERVAL) {
        root.sorted_snapshot(&mut tasks);
        if let Some(event) = advanced_event(&tasks, repo_full_name) {
            sink.report(event);
        }
    }
}

/// Pick the task worth showing and convert it into an event.
///
/// gix nests its phases, so the deepest task carrying a count is the specific
/// one ("Receiving objects") while its ancestors are organizational headings
/// with no count of their own. Ties break on the larger count so a finished
/// sibling never masks the phase still running.
fn advanced_event(tasks: &[(Key, Task)], repo_full_name: &str) -> Option<WorkingCopyProgress> {
    let (_, task) = tasks
        .iter()
        .filter(|(_, task)| task.progress.is_some())
        .max_by_key(|(key, task)| (key.level(), task_done(task)))?;
    let progress = task.progress.as_ref()?;
    Some(WorkingCopyProgress::Advanced {
        repo_full_name: repo_full_name.to_owned(),
        phase: task.name.clone(),
        done: step_as_u64(task_done(task)),
        total: progress.done_at.map(step_as_u64),
        // gix marks a phase it knows cannot advance. A false here is not a
        // promise of health: an ordinary network stall leaves the state
        // `Running` and only shows up as counts that stop moving.
        blocked: matches!(progress.state, State::Blocked(..) | State::Halted(..)),
    })
}

fn task_done(task: &Task) -> usize {
    task.progress
        .as_ref()
        .map_or(0, |progress| progress.step.load(Ordering::Relaxed))
}

fn step_as_u64(value: usize) -> u64 {
    u64::try_from(value).unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests;
