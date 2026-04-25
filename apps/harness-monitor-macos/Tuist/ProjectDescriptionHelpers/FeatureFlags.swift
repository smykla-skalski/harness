import Foundation
import ProjectDescription

public enum FeatureFlag: String, CaseIterable, Sendable {
    case lottie = "HARNESS_FEATURE_LOTTIE"

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

    public static func appAdditionalSourceGlobs(target: String) -> [SourceFileGlob] {
        enabled.flatMap { flag -> [SourceFileGlob] in
            switch flag {
            case .lottie:
                return [.glob("Sources/\(target)/Features/Lottie/**/*.swift")]
            }
        }
    }

    public static func uiPreviewableAdditionalSourceGlobs() -> [SourceFileGlob] {
        enabled.flatMap { flag -> [SourceFileGlob] in
            switch flag {
            case .lottie:
                return [.glob("Sources/HarnessMonitorUIPreviewable/Features/Lottie/**/*.swift")]
            }
        }
    }

    public static func appAdditionalDependencies() -> [TargetDependency] {
        enabled.flatMap { flag -> [TargetDependency] in
            switch flag {
            case .lottie:
                return [.external(name: "Lottie")]
            }
        }
    }

    public static func uiPreviewableAdditionalDependencies() -> [TargetDependency] {
        []
    }
}
