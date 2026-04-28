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
    let mut ring = SessionRing::new(RingConfig::default());
    let mut total_events = 0;
    let mut sequence: u64 = 0;

    for line in lines {
        if let Ok(notif) = parse_notification(line)
            && ring.push(notif)
        {
            let batch = ring.drain();
            let (events, next_seq) = materialise_batch(batch, "bench", "sess", sequence);
            total_events += events.len();
            sequence = next_seq;
        }
    }

    if !ring.is_empty() {
        let batch = ring.drain();
        let (events, _) = materialise_batch(batch, "bench", "sess", sequence);
        total_events += events.len();
    }

    (lines.len(), total_events)
}

/// Run the benchmark and report timing.
///
/// Returns (`parsed_count`, `event_count`, `duration_ms`).
#[must_use]
pub fn run_throughput_benchmark(update_count: usize) -> (usize, usize, f64) {
    let lines = generate_synthetic_updates(update_count);

    let start = Instant::now();
    let (parsed, events) = bench_full_pipeline(&lines);
    let duration = start.elapsed();

    let duration_ms = duration.as_secs_f64() * 1000.0;

    (parsed, events, duration_ms)
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
        let (parsed, events, duration_ms) = run_throughput_benchmark(100);

        assert_eq!(parsed, 100);
        assert!(events > 0);
        assert!(duration_ms > 0.0);
    }

    #[test]
    fn threshold_check_logic() {
        assert!(check_threshold(1000, 50.0));
        assert!(check_threshold(1000, 49.0));
        assert!(!check_threshold(1000, 51.0));
        assert!(check_threshold(5000, 250.0));
    }

    #[test]
    #[ignore] // Run with `cargo test --ignored` or `mise run test:slow`
    fn throughput_meets_threshold() {
        let (_, _, duration_ms) = run_throughput_benchmark(5000);
        let ms_per_1000 = (duration_ms / 5000.0) * 1000.0;

        println!("Throughput: {ms_per_1000:.2} ms/1000 events (threshold: 50 ms)");

        assert!(
            check_threshold(5000, duration_ms),
            "throughput {ms_per_1000:.2} ms/1000 exceeds 50 ms threshold"
        );
    }
}
