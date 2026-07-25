use std::sync::Mutex as StdMutex;
use std::sync::atomic::AtomicUsize;

use gix::progress::Value;
use gix::progress::prodash::progress::Key;

use super::*;

#[derive(Default)]
struct RecordingSink {
    events: StdMutex<Vec<WorkingCopyProgress>>,
}

impl WorkingCopyProgressSink for RecordingSink {
    fn report(&self, event: WorkingCopyProgress) {
        self.events.lock().expect("lock").push(event);
    }
}

impl RecordingSink {
    fn snapshot(&self) -> Vec<WorkingCopyProgress> {
        self.events.lock().expect("lock").clone()
    }
}

fn task(name: &str, done: usize, total: Option<usize>) -> Task {
    Task {
        name: name.to_owned(),
        id: gix::progress::UNKNOWN,
        progress: Some(Value {
            step: Arc::new(AtomicUsize::new(done)),
            done_at: total,
            unit: None,
            state: State::Running,
        }),
    }
}

fn heading(name: &str) -> Task {
    Task {
        name: name.to_owned(),
        id: gix::progress::UNKNOWN,
        progress: None,
    }
}

fn key_at_level(level: u8) -> Key {
    let mut key = Key::default();
    for index in 0..level {
        key = key.add_child(u16::from(index) + 1);
    }
    key
}

#[test]
fn no_event_when_no_task_carries_a_count() {
    let tasks = vec![(key_at_level(1), heading("clone"))];

    assert!(advanced_event(&tasks, "owner/repo").is_none());
}

#[test]
fn reports_the_deepest_counted_task_not_its_heading() {
    let tasks = vec![
        (key_at_level(1), heading("clone")),
        (key_at_level(2), task("Receiving objects", 40, Some(100))),
    ];

    let event = advanced_event(&tasks, "owner/repo").expect("event");

    assert_eq!(
        event,
        WorkingCopyProgress::Advanced {
            repo_full_name: "owner/repo".into(),
            phase: "Receiving objects".into(),
            done: 40,
            total: Some(100),
            blocked: false,
        }
    );
}

#[test]
fn a_finished_sibling_does_not_mask_the_running_phase() {
    let tasks = vec![
        (key_at_level(2), task("Resolving deltas", 12, Some(500))),
        (key_at_level(2), task("Receiving objects", 500, Some(500))),
    ];

    let event = advanced_event(&tasks, "owner/repo").expect("event");

    match event {
        WorkingCopyProgress::Advanced { phase, done, .. } => {
            assert_eq!(phase, "Receiving objects");
            assert_eq!(done, 500);
        }
        other => panic!("expected Advanced, got {other:?}"),
    }
}

#[test]
fn an_unbounded_phase_reports_no_total() {
    let tasks = vec![(key_at_level(1), task("Counting objects", 7, None))];

    let event = advanced_event(&tasks, "owner/repo").expect("event");

    match event {
        WorkingCopyProgress::Advanced { total, done, .. } => {
            assert_eq!(total, None);
            assert_eq!(done, 7);
        }
        other => panic!("expected Advanced, got {other:?}"),
    }
}

#[test]
fn a_halted_phase_is_reported_as_blocked() {
    let mut halted = task("Receiving objects", 3, Some(100));
    halted
        .progress
        .as_mut()
        .expect("progress")
        .state = State::Halted("waiting on remote", None);
    let tasks = vec![(key_at_level(1), halted)];

    let event = advanced_event(&tasks, "owner/repo").expect("event");

    match event {
        WorkingCopyProgress::Advanced { blocked, .. } => assert!(blocked),
        other => panic!("expected Advanced, got {other:?}"),
    }
}

#[test]
fn the_repo_name_rides_along_so_the_ui_can_route_the_event() {
    let tasks = vec![(key_at_level(1), task("Receiving objects", 1, Some(2)))];

    let event = advanced_event(&tasks, "acme/widgets").expect("event");

    assert_eq!(event.repo_full_name(), "acme/widgets");
}

#[test]
fn the_reporter_stops_sampling_once_finished() {
    let sink = Arc::new(RecordingSink::default());
    let reporter =
        CloneProgressReporter::start(Arc::clone(&sink) as Arc<dyn WorkingCopyProgressSink>, "owner/repo".into());
    let progress = reporter.progress();
    progress.set(3);

    reporter.finish();
    let after_finish = sink.snapshot().len();
    thread::sleep(SAMPLE_INTERVAL * 3);

    assert_eq!(sink.snapshot().len(), after_finish);
}
