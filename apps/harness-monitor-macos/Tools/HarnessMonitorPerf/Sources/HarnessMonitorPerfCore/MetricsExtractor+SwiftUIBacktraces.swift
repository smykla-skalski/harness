import Foundation

extension MetricsExtractor {
    static let appBundleTokens = [
        "Harness Monitor.app",
        "Harness Monitor UI Testing.app",
    ]

    struct ResolvedFrame {
        var name: String
        var binaryPath: String
    }

    static func resolveBacktrace(
        in row: XMLElement,
        document: XctraceQueryDocument
    ) -> XMLElement? {
        let children = row.children?.compactMap { $0 as? XMLElement } ?? []
        for child in children {
            guard let resolved = document.dereference(child) else { continue }
            if resolved.name == "backtrace" { return resolved }
        }
        return nil
    }

    static func iterBacktraceFrames(
        _ backtrace: XMLElement,
        document: XctraceQueryDocument
    ) -> [ResolvedFrame] {
        backtrace.elements(forName: "frame").compactMap { frame -> ResolvedFrame? in
            guard let resolved = document.dereference(frame) else { return nil }
            var binaryPath = ""
            if let binary = resolved.elements(forName: "binary").first {
                if binary.attribute(forName: "ref") != nil,
                   let derefBinary = document.dereference(binary)
                {
                    binaryPath = derefBinary.attribute(forName: "path")?.stringValue ?? ""
                } else {
                    binaryPath = binary.attribute(forName: "path")?.stringValue ?? ""
                }
            }
            return ResolvedFrame(
                name: resolved.attribute(forName: "name")?.stringValue ?? "",
                binaryPath: binaryPath
            )
        }
    }

    static func isSymbolicFrame(_ name: String) -> Bool {
        if name.isEmpty || name == "<deduplicated_symbol>" { return false }
        if name.hasPrefix("0x") { return false }
        return true
    }

    static func isAppOwnedBinaryPath(_ binaryPath: String) -> Bool {
        appBundleTokens.contains { binaryPath.contains($0) }
    }

    static func updateGroupFindingPrototype(
        for row: XMLElement,
        label: String,
        document: XctraceQueryDocument
    ) -> (key: String, category: String, headline: String, detail: String?)? {
        guard let backtrace = resolveBacktrace(in: row, document: document) else { return nil }
        let frames = iterBacktraceFrames(backtrace, document: document).filter {
            isSymbolicFrame($0.name)
        }
        guard !frames.isEmpty else { return nil }

        let appOwnedFrame = frames.first(where: { isAppOwnedBinaryPath($0.binaryPath) })?.name
        let fallbackFrame = frames.first(where: {
            !$0.binaryPath.isEmpty && !$0.binaryPath.hasPrefix("/System/")
        })?.name
        guard let primaryFrame = appOwnedFrame ?? fallbackFrame else { return nil }

        let leadFrame = frames.first?.name
        let detail: String? =
            if let leadFrame, leadFrame != primaryFrame {
                "\(leadFrame) -> \(primaryFrame)"
            } else {
                nil
            }
        return (
            key: "update-group:\(slug(label)):\(slug(primaryFrame))",
            category: "swiftui-update-group",
            headline: "\(label) via \(primaryFrame)",
            detail: detail
        )
    }

    static func deduplicatedFindings(_ findings: [CaptureFinding]) -> [CaptureFinding] {
        let index = findings.reduce(into: [String: CaptureFinding]()) { partialResult, finding in
            guard let existing = partialResult[finding.key] else {
                partialResult[finding.key] = finding
                return
            }
            if (finding.count ?? 0) > (existing.count ?? 0) {
                partialResult[finding.key] = finding
                return
            }
            if existing.detail == nil, finding.detail != nil {
                partialResult[finding.key] = finding
            }
        }
        return index.values.sorted {
            if ($0.count ?? 0) != ($1.count ?? 0) {
                return ($0.count ?? 0) > ($1.count ?? 0)
            }
            return $0.key < $1.key
        }
    }

    static func slug(_ value: String) -> String {
        let lowercase = value.lowercased()
        let replaced = lowercase.map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }
        let collapsed = String(replaced)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "unknown" : collapsed
    }

    /// Mirrors `Counter.most_common(n)` - keeps top n entries by count.
    static func topNCounter(_ counts: [String: Int], n: Int) -> [String: Int] {
        let sorted = counts.sorted { $0.value > $1.value }.prefix(n)
        return Dictionary(uniqueKeysWithValues: sorted.map { ($0.key, $0.value) })
    }
}
