import Foundation
import ProjectDescription

public enum FeatureFlag: String, CaseIterable, Sendable {
    case otel = "HARNESS_FEATURE_OTEL"
    case textual = "HARNESS_FEATURE_TEXTUAL"

    public var isEnabled: Bool {
        guard let raw = ProcessInfo.processInfo.environment[rawValue]?.lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(raw)
    }
}

public enum FeatureFlags {
    public static var enabled: [FeatureFlag] {
        FeatureFlag.allCases.filter(\.isEnabled)
    }

    public static var swiftCompilationConditions: [String] {
        enabled.map(\.rawValue)
    }

    public static func compilationConditionSetting() -> SettingValue {
        let conditions = ["$(inherited)"] + swiftCompilationConditions
        return .string(conditions.joined(separator: " "))
    }

    public static func appAdditionalSourceGlobs(target _: String) -> [SourceFileGlob] {
        []
    }

    public static func uiPreviewableAdditionalSourceGlobs() -> [SourceFileGlob] {
        enabled.flatMap { flag -> [SourceFileGlob] in
            switch flag {
            case .otel:
                return []
            case .textual:
                return [.glob("Sources/HarnessMonitorUIPreviewable/Features/Textual/**/*.swift")]
            }
        }
    }

    public static func kitAdditionalSourceGlobs() -> [SourceFileGlob] {
        enabled.flatMap { flag -> [SourceFileGlob] in
            switch flag {
            case .textual:
                return []
            case .otel:
                return [.glob("Sources/HarnessMonitorKit/Features/Otel/**/*.swift")]
            }
        }
    }

    public static func kitTestsAdditionalSourceGlobs() -> [SourceFileGlob] {
        enabled.flatMap { flag -> [SourceFileGlob] in
            switch flag {
            case .textual:
                return []
            case .otel:
                return [.glob("Tests/HarnessMonitorKitTests/Features/Otel/**/*.swift")]
            }
        }
    }

    public static func appAdditionalDependencies() -> [TargetDependency] {
        []
    }

    public static func uiPreviewableAdditionalDependencies() -> [TargetDependency] {
        enabled.flatMap { flag -> [TargetDependency] in
            switch flag {
            case .otel:
                return []
            case .textual:
                return [.external(name: "Textual")]
            }
        }
    }

    public static func kitAdditionalDependencies() -> [TargetDependency] {
        enabled.flatMap { flag -> [TargetDependency] in
            switch flag {
            case .textual:
                return []
            case .otel:
                return [
                    .external(name: "OpenTelemetryApi"),
                    .external(name: "OpenTelemetryConcurrency"),
                    .external(name: "OpenTelemetrySdk"),
                    .external(name: "PersistenceExporter"),
                    .external(name: "OpenTelemetryProtocolExporter"),
                    .external(name: "OpenTelemetryProtocolExporterHTTP"),
                    .external(name: "GRPC")
                ]
            }
        }
    }
}
