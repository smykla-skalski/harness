extension MetricsExtractor {
    public struct TimeProfile: Codable, Equatable {
        public struct Summary: Codable, Equatable {
            public var sampleCount: Int
            public var appOwnedFrameCount: Int
            public var fallbackSymbolicFrameCount: Int

            enum CodingKeys: String, CodingKey {
                case sampleCount = "sample_count"
                case appOwnedFrameCount = "app_owned_frame_count"
                case fallbackSymbolicFrameCount = "fallback_symbolic_frame_count"
            }
        }

        public struct Frame: Codable, Equatable {
            public var name: String
            public var samples: Int
        }

        public var summary: Summary
        public var topFrames: [Frame]
    }

    /// Walks each row's `<backtrace>` looking for the first symbolic frame, preferring frames
    /// whose binary path contains "Harness Monitor.app" / "Harness Monitor UI Testing.app".
    public static func parseTimeProfile(_ document: XctraceQueryDocument) -> TimeProfile {
        var appOwned: [String: Int] = [:]
        var symbolic: [String: Int] = [:]
        var sampleCount = 0

        for row in document.rows {
            sampleCount += 1
            guard let backtrace = resolveBacktrace(in: row, document: document) else { continue }
            var firstSymbolic: String?
            var firstAppOwned: String?

            for frame in iterBacktraceFrames(backtrace, document: document) {
                guard isSymbolicFrame(frame.name) else { continue }
                if firstSymbolic == nil { firstSymbolic = frame.name }
                if isAppOwnedBinaryPath(frame.binaryPath) {
                    firstAppOwned = frame.name
                    break
                }
            }

            if let firstSymbolic { symbolic[firstSymbolic, default: 0] += 1 }
            if let firstAppOwned { appOwned[firstAppOwned, default: 0] += 1 }
        }

        let source = !appOwned.isEmpty ? appOwned : symbolic
        let topFrames = source
            .sorted { $0.value > $1.value }
            .prefix(12)
            .map { TimeProfile.Frame(name: $0.key, samples: $0.value) }

        let summary = TimeProfile.Summary(
            sampleCount: sampleCount,
            appOwnedFrameCount: appOwned.values.reduce(0, +),
            fallbackSymbolicFrameCount: symbolic.values.reduce(0, +)
        )
        return TimeProfile(summary: summary, topFrames: topFrames)
    }
}
