import Foundation

extension SchemaSnapshots {
    static func componentCountSchema() -> RawSchema {
        object(
            required: ["component", "count"],
            properties: [
                "component": scalar("string"),
                "count": scalar("integer"),
            ]
        )
    }

    static func findingSchema() -> RawSchema {
        object(
            required: ["key", "category", "headline"],
            properties: [
                "key": scalar("string"),
                "category": scalar("string"),
                "headline": scalar("string"),
                "detail": scalar("string", nullable: true),
                "count": scalar("integer", nullable: true),
            ]
        )
    }

    static func summaryAppTraceSchema(nullable: Bool = false) -> RawSchema {
        object(
            required: ["relpath", "event_count", "components", "ordered_steps", "step_timings"],
            properties: [
                "relpath": scalar("string"),
                "event_count": scalar("integer"),
                "components": array(items: ref("#/$defs/componentCount")),
                "ordered_steps": array(items: scalar("string")),
                "step_timings": array(items: ref("#/$defs/stepTiming")),
            ],
            nullable: nullable
        )
    }

    static func comparisonAppTraceSummarySchema() -> RawSchema {
        object(
            required: ["event_count", "components", "ordered_steps"],
            properties: [
                "event_count": scalar("integer"),
                "components": array(items: ref("#/$defs/componentCount")),
                "ordered_steps": array(items: scalar("string")),
            ]
        )
    }

    static func stepTimingSchema() -> RawSchema {
        object(
            required: ["step", "start_timestamp", "end_timestamp", "duration_ms"],
            properties: [
                "step": scalar("string"),
                "start_timestamp": scalar("string"),
                "end_timestamp": scalar("string"),
                "duration_ms": scalar("number"),
            ]
        )
    }

    static func appTraceComparisonSchema() -> RawSchema {
        object(
            required: ["new_steps", "resolved_steps"],
            properties: [
                "baseline": oneOf([ref("#/$defs/appTraceSummary"), scalar("null")]),
                "current": oneOf([ref("#/$defs/appTraceSummary"), scalar("null")]),
                "new_steps": array(items: scalar("string")),
                "resolved_steps": array(items: scalar("string")),
            ]
        )
    }

    static func missingCaptureSchema() -> RawSchema {
        object(
            required: ["scenario", "template"],
            properties: [
                "scenario": scalar("string"),
                "template": scalar("string"),
                "reason": scalar("string", nullable: true),
            ]
        )
    }

    static func deltaBlockSchema() -> RawSchema {
        object(
            required: ["baseline", "current", "delta"],
            properties: [
                "baseline": scalar("number"),
                "current": scalar("number"),
                "delta": scalar("number"),
            ]
        )
    }

    static func frameSchema() -> RawSchema {
        object(
            required: ["name", "samples"],
            properties: [
                "name": scalar("string"),
                "samples": scalar("integer"),
            ]
        )
    }
}
