import Foundation

enum LogWarningClassifier {
    static func summary(in logText: String) -> LogProbeRecorder.WarningSummary {
        var summary = LogProbeRecorder.WarningSummary(
            swiftUIFrameUpdateWarnings: 0,
            tableViewReentrantWarnings: 0,
            attributeGraphCycleWarnings: 0,
            databaseOpenWarnings: 0,
            appDataPromptHints: 0,
            duplicateRuntimeClassWarnings: 0,
            stateMutationWarnings: 0,
            mainThreadCheckerWarnings: 0,
            sandboxDenials: 0,
            sqliteWarnings: 0
        )
        var sawTableViewReentrancy = false
        var duplicateRuntimeClasses: Set<String> = []
        for line in logText.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let lowercased = text.lowercased()
            if lowercased.contains("multiple times per frame") {
                summary.swiftUIFrameUpdateWarnings += 1
            }
            if lowercased.contains("nstableview delegate")
                || lowercased.contains("reentrant operation") {
                sawTableViewReentrancy = true
            }
            if lowercased.contains("attributegraph: cycle") {
                summary.attributeGraphCycleWarnings += 1
            }
            if lowercased.contains("unable to open database file") {
                summary.databaseOpenWarnings += 1
            }
            if lowercased.contains("would like to access data from other apps")
                || lowercased.contains("app data") {
                summary.appDataPromptHints += 1
            }
            if lowercased.contains("publishing changes from within view updates")
                || lowercased.contains("modifying state during view update") {
                summary.stateMutationWarnings += 1
            }
            if lowercased.contains("main thread checker") {
                summary.mainThreadCheckerWarnings += 1
            }
            if lowercased.contains("sandbox:") || lowercased.contains(" deny(") {
                summary.sandboxDenials += 1
            }
            if lowercased.contains("sqlite")
                || lowercased.contains("database is locked")
                || lowercased.contains("database disk image is malformed") {
                summary.sqliteWarnings += 1
            }
            if let className = duplicateRuntimeClassName(in: text) {
                duplicateRuntimeClasses.insert(className)
            }
        }
        summary.tableViewReentrantWarnings = sawTableViewReentrancy ? 1 : 0
        summary.duplicateRuntimeClassWarnings = duplicateRuntimeClasses.count
        return summary
    }

    private static func duplicateRuntimeClassName(in line: String) -> String? {
        guard line.contains(" is implemented in both ") else { return nil }
        guard let classRange = line.range(of: "Class ") else { return line }
        let remainder = line[classRange.upperBound...]
        guard let end = remainder.firstIndex(of: " ") else { return String(remainder) }
        return String(remainder[..<end])
    }
}
