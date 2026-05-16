import Foundation

extension Comparator {
    public struct Comparison: Codable, Equatable {
        public var currentLabel: String?
        public var baselineLabel: String?
        public var currentCreatedAtUTC: String?
        public var baselineCreatedAtUTC: String?
        public var missingFromCurrent: [MissingCapture]
        public var missingFromBaseline: [MissingCapture]
        public var currentMissingMetrics: [MissingCapture]
        public var baselineMissingMetrics: [MissingCapture]
        public var expectedButAbsent: [MissingCapture]
        public var comparisons: [CaptureComparison]

        enum CodingKeys: String, CodingKey {
            case currentLabel = "current_label"
            case baselineLabel = "baseline_label"
            case currentCreatedAtUTC = "current_created_at_utc"
            case baselineCreatedAtUTC = "baseline_created_at_utc"
            case missingFromCurrent = "missing_from_current"
            case missingFromBaseline = "missing_from_baseline"
            case currentMissingMetrics = "current_missing_metrics"
            case baselineMissingMetrics = "baseline_missing_metrics"
            case expectedButAbsent = "expected_but_absent"
            case comparisons
        }

        public init(
            currentLabel: String?,
            baselineLabel: String?,
            currentCreatedAtUTC: String?,
            baselineCreatedAtUTC: String?,
            missingFromCurrent: [MissingCapture],
            missingFromBaseline: [MissingCapture],
            currentMissingMetrics: [MissingCapture],
            baselineMissingMetrics: [MissingCapture],
            expectedButAbsent: [MissingCapture] = [],
            comparisons: [CaptureComparison]
        ) {
            self.currentLabel = currentLabel
            self.baselineLabel = baselineLabel
            self.currentCreatedAtUTC = currentCreatedAtUTC
            self.baselineCreatedAtUTC = baselineCreatedAtUTC
            self.missingFromCurrent = missingFromCurrent
            self.missingFromBaseline = missingFromBaseline
            self.currentMissingMetrics = currentMissingMetrics
            self.baselineMissingMetrics = baselineMissingMetrics
            self.expectedButAbsent = expectedButAbsent
            self.comparisons = comparisons
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            currentLabel = try container.decodeIfPresent(String.self, forKey: .currentLabel)
            baselineLabel = try container.decodeIfPresent(String.self, forKey: .baselineLabel)
            currentCreatedAtUTC = try container.decodeIfPresent(
                String.self,
                forKey: .currentCreatedAtUTC
            )
            baselineCreatedAtUTC = try container.decodeIfPresent(
                String.self,
                forKey: .baselineCreatedAtUTC
            )
            missingFromCurrent = try container.decodeIfPresent(
                [MissingCapture].self,
                forKey: .missingFromCurrent
            ) ?? []
            missingFromBaseline = try container.decodeIfPresent(
                [MissingCapture].self,
                forKey: .missingFromBaseline
            ) ?? []
            currentMissingMetrics = try container.decodeIfPresent(
                [MissingCapture].self,
                forKey: .currentMissingMetrics
            ) ?? []
            baselineMissingMetrics = try container.decodeIfPresent(
                [MissingCapture].self,
                forKey: .baselineMissingMetrics
            ) ?? []
            expectedButAbsent = try container.decodeIfPresent(
                [MissingCapture].self,
                forKey: .expectedButAbsent
            ) ?? []
            comparisons = try container.decodeIfPresent(
                [CaptureComparison].self,
                forKey: .comparisons
            ) ?? []
        }
    }

    public struct MissingCapture: Codable, Equatable {
        public var scenario: String
        public var template: String
        public var reason: String?
    }

    public struct CaptureComparison: Codable, Equatable {
        public var scenario: String
        public var template: String
        public var metrics: MetricsBlock
        public var sharedMetrics: [String: DeltaBlock]?
        public var metricTiers: CaptureMetricTiers?
        public var baselineFindings: [CaptureFinding]?
        public var currentFindings: [CaptureFinding]?
        public var newFindings: [CaptureFinding]?
        public var resolvedFindings: [CaptureFinding]?
        public var appTrace: AppTraceComparison?
        public var topFrames: TopFramesPair?

        enum CodingKeys: String, CodingKey {
            case scenario, template, metrics
            case sharedMetrics = "shared_metrics"
            case metricTiers = "metric_tiers"
            case baselineFindings = "baseline_findings"
            case currentFindings = "current_findings"
            case newFindings = "new_findings"
            case resolvedFindings = "resolved_findings"
            case appTrace = "app_trace"
            case topFrames = "top_frames"
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(scenario, forKey: .scenario)
            try container.encode(template, forKey: .template)
            switch metrics {
            case .swiftUI(let map): try container.encode(map, forKey: .metrics)
            case .allocations(let map): try container.encode(map, forKey: .metrics)
            }
            try container.encodeIfPresent(sharedMetrics, forKey: .sharedMetrics)
            try container.encodeIfPresent(metricTiers, forKey: .metricTiers)
            try container.encodeIfPresent(baselineFindings, forKey: .baselineFindings)
            try container.encodeIfPresent(currentFindings, forKey: .currentFindings)
            try container.encodeIfPresent(newFindings, forKey: .newFindings)
            try container.encodeIfPresent(resolvedFindings, forKey: .resolvedFindings)
            try container.encodeIfPresent(appTrace, forKey: .appTrace)
            try container.encodeIfPresent(topFrames, forKey: .topFrames)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scenario = try container.decode(String.self, forKey: .scenario)
            template = try container.decode(String.self, forKey: .template)
            sharedMetrics = try container.decodeIfPresent(
                [String: DeltaBlock].self,
                forKey: .sharedMetrics
            )
            metricTiers = try container.decodeIfPresent(
                CaptureMetricTiers.self,
                forKey: .metricTiers
            )
            baselineFindings = try container.decodeIfPresent(
                [CaptureFinding].self,
                forKey: .baselineFindings
            )
            currentFindings = try container.decodeIfPresent(
                [CaptureFinding].self,
                forKey: .currentFindings
            )
            newFindings = try container.decodeIfPresent(
                [CaptureFinding].self,
                forKey: .newFindings
            )
            resolvedFindings = try container.decodeIfPresent(
                [CaptureFinding].self,
                forKey: .resolvedFindings
            )
            appTrace = try container.decodeIfPresent(
                AppTraceComparison.self,
                forKey: .appTrace
            )
            topFrames = try container.decodeIfPresent(TopFramesPair.self, forKey: .topFrames)
            if template == "Allocations" {
                metrics = .allocations(
                    try container.decode([String: [String: DeltaBlock]].self, forKey: .metrics)
                )
            } else {
                metrics = .swiftUI(try container.decode([String: DeltaBlock].self, forKey: .metrics))
            }
        }

        public init(
            scenario: String,
            template: String,
            metrics: MetricsBlock,
            sharedMetrics: [String: DeltaBlock]? = nil,
            metricTiers: CaptureMetricTiers? = nil,
            baselineFindings: [CaptureFinding]? = nil,
            currentFindings: [CaptureFinding]? = nil,
            newFindings: [CaptureFinding]? = nil,
            resolvedFindings: [CaptureFinding]? = nil,
            appTrace: AppTraceComparison? = nil,
            topFrames: TopFramesPair?
        ) {
            self.scenario = scenario
            self.template = template
            self.metrics = metrics
            self.sharedMetrics = sharedMetrics
            self.metricTiers = metricTiers
            self.baselineFindings = baselineFindings
            self.currentFindings = currentFindings
            self.newFindings = newFindings
            self.resolvedFindings = resolvedFindings
            self.appTrace = appTrace
            self.topFrames = topFrames
        }
    }

    public enum MetricsBlock: Equatable {
        case swiftUI([String: DeltaBlock])
        case allocations([String: [String: DeltaBlock]])
    }

    public struct DeltaBlock: Codable, Equatable {
        public var baseline: Number
        public var current: Number
        public var delta: Number
    }

    public enum Number: Codable, Equatable, CustomStringConvertible {
        case int(Int)
        case double(Double)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let i = try? container.decode(Int.self) {
                self = .int(i)
                return
            }
            if let d = try? container.decode(Double.self) {
                self = .double(d)
                return
            }
            throw DecodingError.typeMismatch(
                Number.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected number")
            )
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .int(let v): try container.encode(v)
            case .double(let v): try container.encode(v)
            }
        }

        public var description: String {
            switch self {
            case .int(let v):
                return String(v)
            case .double(let v):
                if v == v.rounded() { return String(Int64(v)) }
                return String(v)
            }
        }
    }

    public struct TopFramesPair: Codable, Equatable {
        public var baseline: [Frame]
        public var current: [Frame]
    }

    public struct AppTraceSummary: Codable, Equatable {
        public var eventCount: Int
        public var components: [CaptureAppTrace.ComponentCount]
        public var orderedSteps: [String]

        enum CodingKeys: String, CodingKey {
            case eventCount = "event_count"
            case components
            case orderedSteps = "ordered_steps"
        }
    }

    public struct AppTraceComparison: Codable, Equatable {
        public var baseline: AppTraceSummary?
        public var current: AppTraceSummary?
        public var newSteps: [String]
        public var resolvedSteps: [String]

        enum CodingKeys: String, CodingKey {
            case baseline
            case current
            case newSteps = "new_steps"
            case resolvedSteps = "resolved_steps"
        }
    }

    public struct Frame: Codable, Equatable {
        public var name: String
        public var samples: Int
    }
}
