use harness::agents::acp::connection::parse_notification;
use harness::agents::acp::events::materialise_batch;
use harness::agents::acp::ring::{RingConfig, SessionRing};
use harness::agents::acp::throughput_bench::{
    CI_UPDATE_COUNT, MAX_TRACKED_ALLOCATIONS_PER_EVENT, bench_full_pipeline_with_stats,
    generate_synthetic_updates,
};
use harness::agents::runtime::event::{ConversationEvent, ConversationEventKind};

#[test]
fn synthetic_acp_stream_flushes_to_stable_conversation_events() {
    let lines = generate_synthetic_updates(96);

    let first = materialise_synthetic_stream(&lines);
    let second = materialise_synthetic_stream(&lines);

    assert_eq!(first.batch_sizes, vec![32, 32, 32]);
    assert_eq!(first.signature, second.signature);
    assert_eq!(first.events.len(), second.events.len());
    assert_eq!(first.events.first().map(|event| event.sequence), Some(0));
    assert!(first.events.iter().any(|event| {
        matches!(
            event.kind,
            ConversationEventKind::ToolInvocation { .. } | ConversationEventKind::ToolResult { .. }
        )
    }));
}

#[test]
fn synthetic_acp_throughput_keeps_tracked_allocations_bounded() {
    let lines = generate_synthetic_updates(CI_UPDATE_COUNT);
    let stats = bench_full_pipeline_with_stats(&lines);

    assert_eq!(stats.parsed_count, CI_UPDATE_COUNT);
    assert!(stats.event_count > 0);
    assert!(stats.batch_count > 0);
    assert!(
        stats.tracked_allocations_per_event() <= MAX_TRACKED_ALLOCATIONS_PER_EVENT,
        "tracked allocations/event exceeded chunk 6 budget"
    );
}

struct StreamResult {
    events: Vec<ConversationEvent>,
    batch_sizes: Vec<usize>,
    signature: Vec<String>,
}

fn materialise_synthetic_stream(lines: &[String]) -> StreamResult {
    let mut ring = SessionRing::new(RingConfig::default());
    let mut sequence = 0;
    let mut events = Vec::new();
    let mut batch_sizes = Vec::new();

    for line in lines {
        let notification = parse_notification(line).expect("synthetic notification parses");
        if ring.push(notification) {
            flush_ring(&mut ring, &mut sequence, &mut events, &mut batch_sizes);
        }
    }

    if !ring.is_empty() {
        flush_ring(&mut ring, &mut sequence, &mut events, &mut batch_sizes);
    }

    let signature = events
        .iter()
        .map(|event| {
            format!(
                "{}:{}:{}",
                event.agent,
                event.session_id,
                event_kind(&event.kind)
            )
        })
        .collect();

    StreamResult {
        events,
        batch_sizes,
        signature,
    }
}

fn flush_ring(
    ring: &mut SessionRing,
    sequence: &mut u64,
    events: &mut Vec<ConversationEvent>,
    batch_sizes: &mut Vec<usize>,
) {
    batch_sizes.push(ring.len());
    let (batch_events, next_sequence) =
        materialise_batch(ring.updates(), "bench", "sess", *sequence);
    *sequence = next_sequence;
    ring.clear();
    events.extend(batch_events);
}

fn event_kind(kind: &ConversationEventKind) -> &'static str {
    match kind {
        ConversationEventKind::UserPrompt { .. } => "user_prompt",
        ConversationEventKind::AssistantText { .. } => "assistant_text",
        ConversationEventKind::ToolInvocation { .. } => "tool_invocation",
        ConversationEventKind::ToolResult { .. } => "tool_result",
        ConversationEventKind::Error { .. } => "error",
        ConversationEventKind::StateChange { .. } => "state_change",
        ConversationEventKind::FileModification { .. } => "file_modification",
        ConversationEventKind::SessionMarker { .. } => "session_marker",
        ConversationEventKind::SignalReceived { .. } => "signal_received",
        ConversationEventKind::Other { .. } => "other",
    }
}
