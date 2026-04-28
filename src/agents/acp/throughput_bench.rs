//! Throughput benchmark for ACP event processing.
//!
//! Feeds 5000 synthetic NDJSON updates through the parsing and materialisation
//! pipeline. Asserts:
//! - wall-time/1000-events ≤ 50 ms on dev box
//! - CI gate: fail on >2× regression vs committed baseline
//!
//! Run with: `cargo bench --bench acp_throughput`

use std::time::Instant;

use agent_client_protocol::schema::{
    ContentBlock, ContentChunk, SessionId, SessionNotification, SessionUpdate, TextContent,
    ToolCall, ToolCallId, ToolCallStatus, ToolCallUpdate, ToolCallUpdateFields, ToolKind,
};

use super::connection::parse_notification;
use super::events::materialise_batch;
use super::ring::{RingConfig, SessionRing};

/// Number of synthetic updates used by the fast CI throughput gate.
pub const CI_UPDATE_COUNT: usize = 5_000;

/// Committed development-machine timing baseline in milliseconds per 1000 raw updates.
pub const BASELINE_MS_PER_1000_UPDATES: f64 = 50.0;

/// Maximum allowed CI timing regression relative to [`BASELINE_MS_PER_1000_UPDATES`].
pub const MAX_CI_REGRESSION_FACTOR: f64 = 2.0;

/// Maximum tracked hot-path allocation events per materialised event.
pub const MAX_TRACKED_ALLOCATIONS_PER_EVENT: f64 = 4.0;

/// Metrics collected by the synthetic throughput path.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PipelineStats {
    /// Raw NDJSON lines accepted by the parser.
    pub parsed_count: usize,
    /// Conversation events emitted by the materialiser.
    pub event_count: usize,
    /// Fold-flush batches emitted by the ring.
    pub batch_count: usize,
    /// Reallocations observed on the reused ring buffer.
    pub ring_reallocations: usize,
    /// Event batch vector allocations, one per non-empty materialised batch.
    pub event_batch_allocations: usize,
}

impl PipelineStats {
    /// Tracked allocation events per materialised conversation event.
    #[must_use]
    pub fn tracked_allocations_per_event(self) -> f64 {
        if self.event_count == 0 {
            return f64::INFINITY;
        }
        let allocation_events = self.ring_reallocations + self.event_batch_allocations;
        let Ok(allocation_events) = u32::try_from(allocation_events) else {
            return f64::INFINITY;
        };
        let Ok(event_count) = u32::try_from(self.event_count) else {
            return f64::INFINITY;
        };
        f64::from(allocation_events) / f64::from(event_count)
    }
}

/// Generate synthetic NDJSON lines for benchmarking.
///
/// Returns a mix of message chunks, tool calls, and tool updates to simulate
/// realistic agent output.
///
/// # Panics
///
/// Panics if one of the synthetic ACP notifications cannot be serialized.
#[must_use]
pub fn generate_synthetic_updates(count: usize) -> Vec<String> {
    let mut lines = Vec::with_capacity(count);

    for i in 0..count {
        let update = match i % 5 {
            0 => SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                TextContent::new(format!(
                    "This is message chunk number {i} with some content to process."
                )),
            ))),
            1 => SessionUpdate::ToolCall(
                ToolCall::new(ToolCallId::new(format!("tc-{i}")), format!("Read file {i}"))
                    .kind(ToolKind::Read)
                    .raw_input(Some(
                        serde_json::json!({"path": format!("/path/to/file{i}.txt")}),
                    )),
            ),
            2 => SessionUpdate::ToolCallUpdate(ToolCallUpdate::new(
                ToolCallId::new(format!("tc-{}", i - 1)),
                ToolCallUpdateFields::default().status(ToolCallStatus::InProgress),
            )),
            3 => SessionUpdate::ToolCallUpdate(ToolCallUpdate::new(
                ToolCallId::new(format!("tc-{}", i - 2)),
                ToolCallUpdateFields::default()
                    .status(ToolCallStatus::Completed)
                    .raw_output(serde_json::json!({"content": "file contents here"})),
            )),
            _ => SessionUpdate::AgentThoughtChunk(ContentChunk::new(ContentBlock::Text(
                TextContent::new(format!("Thinking about step {i}...")),
            ))),
        };

        let notif = SessionNotification::new(SessionId::new("bench-session"), update);
        let json = serde_json::to_string(&notif).expect("failed to serialize");
        lines.push(json);
    }

    lines
}

/// Benchmark: parse 5000 NDJSON lines.
#[must_use]
pub fn bench_parse_notifications(lines: &[String]) -> usize {
    let mut count = 0;
    for line in lines {
        if parse_notification(line).is_ok() {
            count += 1;
        }
    }
    count
}

/// Benchmark: ring buffer push and flush.
#[must_use]
pub fn bench_ring_buffer(notifications: Vec<SessionNotification>) -> usize {
    let mut ring = SessionRing::new(RingConfig::default());
    let mut batch_count = 0;

    for notif in notifications {
        if ring.push(notif) {
            let _ = ring.drain();
            batch_count += 1;
        }
    }

    if !ring.is_empty() {
        let _ = ring.drain();
        batch_count += 1;
    }

    batch_count
}

/// Benchmark: full pipeline (parse -> ring -> materialise).
#[must_use]
pub fn bench_full_pipeline(lines: &[String]) -> (usize, usize) {
    let stats = bench_full_pipeline_with_stats(lines);
    (stats.parsed_count, stats.event_count)
}

/// Benchmark: full pipeline with allocation and batching metrics.
#[must_use]
pub fn bench_full_pipeline_with_stats(lines: &[String]) -> PipelineStats {
    let mut ring = SessionRing::new(RingConfig::default());
    let mut sequence: u64 = 0;
    let mut stats = PipelineStats {
        parsed_count: 0,
        event_count: 0,
        batch_count: 0,
        ring_reallocations: 0,
        event_batch_allocations: 0,
    };

    for line in lines {
        let Ok(notif) = parse_notification(line) else {
            continue;
        };
        stats.parsed_count += 1;
        let capacity_before = ring.capacity();
        if ring.push(notif) {
            if ring.capacity() != capacity_before {
                stats.ring_reallocations += 1;
            }
            materialise_ring(&mut ring, &mut sequence, &mut stats);
        } else if ring.capacity() != capacity_before {
            stats.ring_reallocations += 1;
        }
    }

    if !ring.is_empty() {
        materialise_ring(&mut ring, &mut sequence, &mut stats);
    }

    stats
}

fn materialise_ring(ring: &mut SessionRing, sequence: &mut u64, stats: &mut PipelineStats) {
    let (events, next_sequence) = materialise_batch(ring.updates(), "bench", "sess", *sequence);
    *sequence = next_sequence;
    stats.event_count += events.len();
    stats.batch_count += 1;
    if events.capacity() > 0 {
        stats.event_batch_allocations += 1;
    }
    ring.clear();
}

/// Run the benchmark and report timing.
///
/// Returns (`parsed_count`, `event_count`, `duration_ms`, `pipeline_stats`).
#[must_use]
pub fn run_throughput_benchmark(update_count: usize) -> (usize, usize, f64, PipelineStats) {
    let lines = generate_synthetic_updates(update_count);

    let start = Instant::now();
    let stats = bench_full_pipeline_with_stats(&lines);
    let duration = start.elapsed();

    let duration_ms = duration.as_secs_f64() * 1000.0;

    (stats.parsed_count, stats.event_count, duration_ms, stats)
}

/// Check if the benchmark meets the performance threshold.
///
/// Threshold: ≤ 50 ms per 1000 events.
#[must_use]
pub fn check_threshold(update_count: usize, duration_ms: f64) -> bool {
    let Ok(update_count) = u32::try_from(update_count) else {
        return false;
    };
    if update_count == 0 {
        return false;
    }
    let ms_per_1000 = (duration_ms / f64::from(update_count)) * 1000.0;
    ms_per_1000 <= 50.0
}

/// Check if the benchmark stays within the committed CI regression allowance.
#[must_use]
pub fn check_ci_regression(update_count: usize, duration_ms: f64) -> bool {
    let Ok(update_count) = u32::try_from(update_count) else {
        return false;
    };
    if update_count == 0 {
        return false;
    }
    let ms_per_1000 = (duration_ms / f64::from(update_count)) * 1000.0;
    ms_per_1000 <= BASELINE_MS_PER_1000_UPDATES * MAX_CI_REGRESSION_FACTOR
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generate_synthetic_updates_correct_count() {
        let updates = generate_synthetic_updates(100);
        assert_eq!(updates.len(), 100);
    }

    #[test]
    fn synthetic_updates_are_valid_json() {
        let updates = generate_synthetic_updates(50);
        for line in &updates {
            assert!(parse_notification(line).is_ok(), "failed to parse: {line}");
        }
    }

    #[test]
    fn bench_parse_notifications_counts_correctly() {
        let lines = generate_synthetic_updates(100);
        let count = bench_parse_notifications(&lines);
        assert_eq!(count, 100);
    }

    #[test]
    fn bench_ring_buffer_produces_batches() {
        let lines = generate_synthetic_updates(100);
        let notifications: Vec<_> = lines
            .iter()
            .filter_map(|l| parse_notification(l).ok())
            .collect();

        let batch_count = bench_ring_buffer(notifications);
        assert!(batch_count >= 3); // 100 updates with default 32 threshold
    }

    #[test]
    fn bench_full_pipeline_processes_all() {
        let lines = generate_synthetic_updates(100);
        let (parsed, events) = bench_full_pipeline(&lines);

        assert_eq!(parsed, 100);
        assert!(events > 0);
    }

    #[test]
    fn throughput_benchmark_runs() {
        let (parsed, events, duration_ms, stats) = run_throughput_benchmark(100);

        assert_eq!(parsed, 100);
        assert!(events > 0);
        assert!(duration_ms > 0.0);
        assert_eq!(stats.parsed_count, 100);
        assert!(stats.batch_count > 0);
    }

    #[test]
    fn threshold_check_logic() {
        assert!(check_threshold(1000, 50.0));
        assert!(check_threshold(1000, 49.0));
        assert!(!check_threshold(1000, 51.0));
        assert!(check_threshold(5000, 250.0));
    }

    #[test]
    fn ci_regression_check_logic() {
        let allowed = BASELINE_MS_PER_1000_UPDATES * MAX_CI_REGRESSION_FACTOR;
        assert!(check_ci_regression(1000, allowed));
        assert!(!check_ci_regression(1000, allowed + 1.0));
    }

    #[test]
    fn throughput_ci_gate_meets_committed_baseline() {
        let (_, _, duration_ms, stats) = run_throughput_benchmark(CI_UPDATE_COUNT);
        let update_count = u32::try_from(CI_UPDATE_COUNT).expect("CI count fits u32");
        let ms_per_1000 = (duration_ms / f64::from(update_count)) * 1000.0;
        let allocs_per_event = stats.tracked_allocations_per_event();

        assert_eq!(stats.parsed_count, CI_UPDATE_COUNT);
        assert!(stats.event_count > 0);
        assert!(
            check_ci_regression(CI_UPDATE_COUNT, duration_ms),
            "throughput {ms_per_1000:.2} ms/1000 exceeds 2x committed baseline"
        );
        assert!(
            allocs_per_event <= MAX_TRACKED_ALLOCATIONS_PER_EVENT,
            "tracked allocations/event {allocs_per_event:.2} exceeds {MAX_TRACKED_ALLOCATIONS_PER_EVENT}"
        );
    }

    #[test]
    #[ignore] // Run with `cargo test --ignored` or `mise run test:slow`
    fn throughput_meets_threshold() {
        let (_, _, duration_ms, _) = run_throughput_benchmark(CI_UPDATE_COUNT);
        let update_count = u32::try_from(CI_UPDATE_COUNT).expect("CI count fits u32");
        let ms_per_1000 = (duration_ms / f64::from(update_count)) * 1000.0;

        println!("Throughput: {ms_per_1000:.2} ms/1000 events (threshold: 50 ms)");

        assert!(
            check_threshold(CI_UPDATE_COUNT, duration_ms),
            "throughput {ms_per_1000:.2} ms/1000 exceeds 50 ms threshold"
        );
    }
}
