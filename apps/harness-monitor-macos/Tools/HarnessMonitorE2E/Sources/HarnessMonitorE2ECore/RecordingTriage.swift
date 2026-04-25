import CoreGraphics
import Foundation
import ImageIO

/// Detection routines for the swarm e2e recording-triage pipeline.
///
/// Each routine takes structured input (timestamps, hierarchy text, image URLs)
/// and emits a Codable report so the shell wrappers under
/// `scripts/e2e/recording-triage/` can serialise findings to JSON without
/// re-implementing the math in shell.
public enum RecordingTriage {
    public static let hitchThresholdSeconds: Double = 0.050
    public static let freezeThresholdSeconds: Double = 2.0
    public static let stallThresholdSeconds: Double = 5.0
    public static let blackLuminanceThreshold: Double = 5.0
    public static let blackUniqueColorThreshold: Int = 10
    public static let layoutDriftPointThreshold: CGFloat = 2.0
    public static let perceptualHashGroundTruthDistanceThreshold: Int = 14
}

// MARK: - Frame gaps

extension RecordingTriage {
    public enum FrameGapKind: String, Codable, Sendable {
        case hitch
        case freeze
        case stall
    }

    public struct FrameGap: Codable, Equatable, Sendable {
        public let startSeconds: Double
        public let endSeconds: Double
        public let durationSeconds: Double
        public let kind: FrameGapKind

        public init(startSeconds: Double, endSeconds: Double, kind: FrameGapKind) {
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.durationSeconds = endSeconds - startSeconds
            self.kind = kind
        }
    }

    public struct FrameGapReport: Codable, Equatable, Sendable {
        public let totalFrames: Int
        public let durationSeconds: Double
        public let hitches: [FrameGap]
        public let freezes: [FrameGap]
        public let stalls: [FrameGap]
    }

    /// Classify per-frame timestamps from ffprobe into hitches, freezes, and stalls.
    /// `idleSegments` describes wall-clock ranges where the act-driver log was
    /// silent (no UI activity); gaps inside these are downgraded to stalls if
    /// over the stall threshold but never up-promoted to freezes.
    public static func analyzeFrameGaps(
        timestamps: [Double],
        idleSegments: [ClosedRange<Double>] = []
    ) -> FrameGapReport {
        guard timestamps.count >= 2 else {
            let duration = timestamps.last ?? 0
            return FrameGapReport(
                totalFrames: timestamps.count,
                durationSeconds: duration,
                hitches: [],
                freezes: [],
                stalls: []
            )
        }

        var hitches: [FrameGap] = []
        var freezes: [FrameGap] = []
        var stalls: [FrameGap] = []

        for index in 1..<timestamps.count {
            let start = timestamps[index - 1]
            let end = timestamps[index]
            let delta = end - start
            guard delta > hitchThresholdSeconds else { continue }

            let isInsideIdle = idleSegments.contains { $0.contains(start) }

            if delta > stallThresholdSeconds, isInsideIdle {
                stalls.append(FrameGap(startSeconds: start, endSeconds: end, kind: .stall))
            } else if delta > freezeThresholdSeconds {
                freezes.append(FrameGap(startSeconds: start, endSeconds: end, kind: .freeze))
            } else {
                hitches.append(FrameGap(startSeconds: start, endSeconds: end, kind: .hitch))
            }
        }

        return FrameGapReport(
            totalFrames: timestamps.count,
            durationSeconds: timestamps.last ?? 0,
            hitches: hitches,
            freezes: freezes,
            stalls: stalls
        )
    }

    /// Parse ffprobe's `-show_frames -of compact=p=0` output into a list of
    /// frame timestamps in seconds. Modern ffprobe (>= 5.0) emits `pts_time=`;
    /// older builds use `pkt_pts_time=`. Both spellings count as one timestamp
    /// per frame, but never both — once a frame yields a timestamp we move on
    /// so legacy builds emitting both fields don't double-count.
    public static func parseFrameTimestamps(fromFFprobe output: String) -> [Double] {
        var timestamps: [Double] = []
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            var captured: Double?
            for token in line.split(separator: "|") {
                let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                guard key == "pts_time" || key == "pkt_pts_time" else { continue }
                if let value = Double(parts[1]) {
                    captured = value
                    break
                }
            }
            if let captured {
                timestamps.append(captured)
            }
        }
        return timestamps
    }
}

// MARK: - Dead head / tail

extension RecordingTriage {
    public struct DeadHeadTailReport: Codable, Equatable, Sendable {
        public let leadingSeconds: Double
        public let trailingSeconds: Double
        public let isLeadingDead: Bool
        public let isTrailingDead: Bool
        public let threshold: Double

        public init(
            leadingSeconds: Double,
            trailingSeconds: Double,
            threshold: Double
        ) {
            self.leadingSeconds = leadingSeconds
            self.trailingSeconds = trailingSeconds
            self.threshold = threshold
            self.isLeadingDead = leadingSeconds > threshold
            self.isTrailingDead = trailingSeconds > threshold
        }
    }

    /// Compare the recording's first/last frame timestamps against the
    /// daemon-log's app-launch / terminate markers. Inputs are seconds since
    /// arbitrary epoch — only the deltas matter.
    public static func analyzeDeadHeadTail(
        recordingStartEpoch: Double,
        recordingEndEpoch: Double,
        appLaunchEpoch: Double,
        appTerminateEpoch: Double,
        threshold: Double = 5.0
    ) -> DeadHeadTailReport {
        DeadHeadTailReport(
            leadingSeconds: max(0, appLaunchEpoch - recordingStartEpoch),
            trailingSeconds: max(0, recordingEndEpoch - appTerminateEpoch),
            threshold: threshold
        )
    }
}

// MARK: - Perceptual hash (dHash)

extension RecordingTriage {
    public struct PerceptualHash: Codable, Equatable, Sendable, Hashable {
        public let bits: UInt64

        public init(bits: UInt64) { self.bits = bits }

        public func distance(to other: PerceptualHash) -> Int {
            (bits ^ other.bits).nonzeroBitCount
        }
    }

    public enum PerceptualHashError: Error, CustomStringConvertible {
        case sourceCreationFailed(URL)
        case imageDecodeFailed(URL)
        case bitmapContextFailed

        public var description: String {
            switch self {
            case .sourceCreationFailed(let url): "CGImageSourceCreateWithURL failed: \(url.path)"
            case .imageDecodeFailed(let url): "CGImageSourceCreateImageAtIndex failed: \(url.path)"
            case .bitmapContextFailed: "Failed to allocate CGContext for dHash"
            }
        }
    }

    /// Difference hash (dHash). Resize to 9x8 grayscale and emit 64 bits, one
    /// per `pixel(x, y) > pixel(x+1, y)` comparison. Hamming distance between
    /// two hashes equals the count of differing bits.
    public static func perceptualHash(of image: CGImage) throws -> PerceptualHash {
        let width = 9
        let height = 8
        var bytes = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard
            let context = CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else {
            throw PerceptualHashError.bitmapContextFailed
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var bits: UInt64 = 0
        for row in 0..<height {
            for column in 0..<8 {
                let left = bytes[row * width + column]
                let right = bytes[row * width + column + 1]
                if left > right {
                    bits |= 1 << (row * 8 + column)
                }
            }
        }
        return PerceptualHash(bits: bits)
    }

    public static func perceptualHash(ofImageAt url: URL) throws -> PerceptualHash {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PerceptualHashError.sourceCreationFailed(url)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PerceptualHashError.imageDecodeFailed(url)
        }
        return try perceptualHash(of: image)
    }

    public struct PerceptualHashFinding: Codable, Equatable, Sendable {
        public let candidate: String
        public let groundTruth: String
        public let distance: Int
        public let exceedsThreshold: Bool
    }

    public static func compareKeyframes(
        candidates: [(name: String, url: URL)],
        groundTruths: [(name: String, url: URL)],
        threshold: Int = perceptualHashGroundTruthDistanceThreshold
    ) throws -> [PerceptualHashFinding] {
        let groundTruthIndex = Dictionary(uniqueKeysWithValues: groundTruths.map { ($0.name, $0.url) })
        var findings: [PerceptualHashFinding] = []
        for candidate in candidates {
            guard let groundTruthURL = groundTruthIndex[candidate.name] else { continue }
            let candidateHash = try perceptualHash(ofImageAt: candidate.url)
            let groundTruthHash = try perceptualHash(ofImageAt: groundTruthURL)
            let distance = candidateHash.distance(to: groundTruthHash)
            findings.append(PerceptualHashFinding(
                candidate: candidate.url.path,
                groundTruth: groundTruthURL.path,
                distance: distance,
                exceedsThreshold: distance > threshold
            ))
        }
        return findings
    }
}

// MARK: - Layout drift

extension RecordingTriage {
    public struct LayoutBoundingBox: Codable, Equatable, Sendable {
        public let identifier: String
        public let frame: CGRect
    }

    public struct LayoutDrift: Codable, Equatable, Sendable {
        public let identifier: String
        public let beforeFrame: CGRect
        public let afterFrame: CGRect
        public let dx: CGFloat
        public let dy: CGFloat
    }

    /// Parse `XCUIElement.debugDescription` style hierarchy text. Looks for
    /// lines that contain `identifier=<id>` and a `{x, y}, {w, h}` frame.
    public static func parseLayoutBoundingBoxes(from text: String) -> [LayoutBoundingBox] {
        var boxes: [LayoutBoundingBox] = []
        let pattern = #"identifier=['\"]?([^,'\"\s]+)['\"]?[^\n]*?\{\{(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)\},\s*\{(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return boxes
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            guard match.numberOfRanges == 6 else { continue }
            let identifier = nsText.substring(with: match.range(at: 1))
            guard
                let originX = Double(nsText.substring(with: match.range(at: 2))),
                let originY = Double(nsText.substring(with: match.range(at: 3))),
                let width = Double(nsText.substring(with: match.range(at: 4))),
                let height = Double(nsText.substring(with: match.range(at: 5)))
            else {
                continue
            }
            boxes.append(LayoutBoundingBox(
                identifier: identifier,
                frame: CGRect(x: originX, y: originY, width: width, height: height)
            ))
        }
        return boxes
    }

    public static func detectLayoutDrift(
        before: [LayoutBoundingBox],
        after: [LayoutBoundingBox],
        threshold: CGFloat = layoutDriftPointThreshold
    ) -> [LayoutDrift] {
        let afterIndex = Dictionary(grouping: after, by: { $0.identifier })
        var drifts: [LayoutDrift] = []
        for box in before {
            guard let candidates = afterIndex[box.identifier], let next = candidates.first else { continue }
            let dx = next.frame.origin.x - box.frame.origin.x
            let dy = next.frame.origin.y - box.frame.origin.y
            if abs(dx) > threshold || abs(dy) > threshold {
                drifts.append(LayoutDrift(
                    identifier: box.identifier,
                    beforeFrame: box.frame,
                    afterFrame: next.frame,
                    dx: dx,
                    dy: dy
                ))
            }
        }
        return drifts
    }
}

// MARK: - Black / blank frames

extension RecordingTriage {
    public struct BlackFrameReport: Codable, Equatable, Sendable {
        public let path: String
        public let meanLuminance: Double
        public let uniqueColorCount: Int
        public let isSuspect: Bool
    }

    public enum BlackFrameError: Error, CustomStringConvertible {
        case sourceCreationFailed(URL)
        case imageDecodeFailed(URL)
        case bitmapContextFailed

        public var description: String {
            switch self {
            case .sourceCreationFailed(let url): "CGImageSourceCreateWithURL failed: \(url.path)"
            case .imageDecodeFailed(let url): "CGImageSourceCreateImageAtIndex failed: \(url.path)"
            case .bitmapContextFailed: "Failed to allocate CGContext for black-frame analyser"
            }
        }
    }

    public static func analyseBlackFrame(at url: URL) throws -> BlackFrameReport {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw BlackFrameError.sourceCreationFailed(url)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw BlackFrameError.imageDecodeFailed(url)
        }
        // Downsample to 32x32 RGBA so unique-color counting and luminance
        // averaging stay cheap regardless of source resolution.
        let width = 32
        let height = 32
        let pixelCount = width * height
        var bytes = [UInt8](repeating: 0, count: pixelCount * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard
            let context = CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        else {
            throw BlackFrameError.bitmapContextFailed
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luminanceSum: Double = 0
        var seenColors = Set<UInt32>()
        for index in 0..<pixelCount {
            let offset = index * 4
            let red = Double(bytes[offset])
            let green = Double(bytes[offset + 1])
            let blue = Double(bytes[offset + 2])
            // Rec. 601 luma; matches what most video pipelines treat as
            // "perceived brightness" for thumbnails.
            luminanceSum += 0.299 * red + 0.587 * green + 0.114 * blue
            let packed = (UInt32(bytes[offset]) << 16)
                | (UInt32(bytes[offset + 1]) << 8)
                | UInt32(bytes[offset + 2])
            seenColors.insert(packed)
        }
        let meanLuminance = luminanceSum / Double(pixelCount)
        let uniqueColors = seenColors.count
        let suspect = meanLuminance < blackLuminanceThreshold
            || uniqueColors < blackUniqueColorThreshold
        return BlackFrameReport(
            path: url.path,
            meanLuminance: meanLuminance,
            uniqueColorCount: uniqueColors,
            isSuspect: suspect
        )
    }
}

// MARK: - Act markers

extension RecordingTriage {
    public enum ActMarkerKind: String, Codable, Sendable {
        case ready
        case ack
    }

    public struct ActMarker: Codable, Equatable, Sendable {
        public let act: String
        public let kind: ActMarkerKind
        public let payload: [String: String]
        public let mtime: Date
    }

    public enum ActMarkerError: Error, CustomStringConvertible {
        case unknownSuffix(URL)
        case missingFile(URL)
        case missingMTime(URL)

        public var description: String {
            switch self {
            case .unknownSuffix(let url):
                "expected .ready or .ack suffix: \(url.lastPathComponent)"
            case .missingFile(let url):
                "marker file missing: \(url.path)"
            case .missingMTime(let url):
                "marker has no modificationDate: \(url.path)"
            }
        }
    }

    /// Parse an `<act>.ready` or `<act>.ack` marker file written atomically by
    /// `SwarmFullFlowOrchestrator.actReady` / `actAck`. The act name is taken
    /// from the filename, the kind from the extension, the payload from the
    /// `key=value` lines (one per line; blank lines and `#`-prefixed comments
    /// skipped; the literal `ack` token used by ack files contributes nothing
    /// to the payload), and the wall-clock anchor from the file's mtime.
    public static func parseActMarker(at url: URL) throws -> ActMarker {
        let kind: ActMarkerKind
        switch url.pathExtension {
        case "ready": kind = .ready
        case "ack": kind = .ack
        default: throw ActMarkerError.unknownSuffix(url)
        }
        let act = url.deletingPathExtension().lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ActMarkerError.missingFile(url)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let mtime = attrs[.modificationDate] as? Date else {
            throw ActMarkerError.missingMTime(url)
        }
        let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var payload: [String: String] = [:]
        for rawLine in body.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line == "ack" { continue }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty || key == "act" { continue }
            payload[key] = value
        }
        return ActMarker(act: act, kind: kind, payload: payload, mtime: mtime)
    }
}

// MARK: - Act timing

extension RecordingTriage {
    public struct ActWindow: Codable, Equatable, Sendable {
        public let act: String
        public let readySeconds: Double?
        public let ackSeconds: Double?
        public let durationSeconds: Double?
        public let gapToNextSeconds: Double?
    }

    public struct ActTimingReport: Codable, Equatable, Sendable {
        public let ttffSeconds: Double
        public let dashboardLatencySeconds: Double?
        public let acts: [ActWindow]
    }

    /// Convert marker mtimes into recording-relative offsets so the checklist
    /// emitter can drive `lifecycle.ttff`, `lifecycle.dashboard`, and the
    /// suite-speed handoff verdicts without re-reading the filesystem.
    /// Per-act ack/duration/handoff fields stay nil when their input marker
    /// is missing so callers can distinguish "not yet acked" from "0 seconds".
    public static func analyzeActTiming(
        markers: [ActMarker],
        recordingStart: Date,
        appLaunch: Date
    ) -> ActTimingReport {
        let recordingEpoch = recordingStart.timeIntervalSince1970
        let ttff = max(0, recordingEpoch - appLaunch.timeIntervalSince1970)

        var readyByAct: [String: Date] = [:]
        var ackByAct: [String: Date] = [:]
        var actNames: [String] = []
        for marker in markers {
            switch marker.kind {
            case .ready:
                if readyByAct[marker.act] == nil {
                    readyByAct[marker.act] = marker.mtime
                    actNames.append(marker.act)
                }
            case .ack:
                ackByAct[marker.act] = marker.mtime
            }
        }

        let orderedActs = actNames.sorted { lhs, rhs in
            let lhsMtime = readyByAct[lhs] ?? .distantFuture
            let rhsMtime = readyByAct[rhs] ?? .distantFuture
            return lhsMtime < rhsMtime
        }

        var windows: [ActWindow] = []
        for (index, act) in orderedActs.enumerated() {
            let ready = readyByAct[act].map { $0.timeIntervalSince1970 - recordingEpoch }
            let ack = ackByAct[act].map { $0.timeIntervalSince1970 - recordingEpoch }
            let duration: Double? = {
                guard let ready, let ack else { return nil }
                return ack - ready
            }()
            let gap: Double? = {
                guard index + 1 < orderedActs.count, let ack else { return nil }
                let next = orderedActs[index + 1]
                guard let nextReady = readyByAct[next].map({ $0.timeIntervalSince1970 - recordingEpoch }) else { return nil }
                return nextReady - ack
            }()
            windows.append(ActWindow(
                act: act,
                readySeconds: ready,
                ackSeconds: ack,
                durationSeconds: duration,
                gapToNextSeconds: gap
            ))
        }

        let dashboard = readyByAct["act1"].map { $0.timeIntervalSince1970 - recordingEpoch }
        return ActTimingReport(
            ttffSeconds: ttff,
            dashboardLatencySeconds: dashboard,
            acts: windows
        )
    }
}

// MARK: - Animation thrash

extension RecordingTriage {
    public struct ThrashWindow: Codable, Equatable, Sendable {
        public let startSeconds: Double
        public let endSeconds: Double
        public let perceptualChanges: Int
    }

    public struct ThrashReport: Codable, Equatable, Sendable {
        public let windowSeconds: Double
        public let changeThreshold: Int
        public let windows: [ThrashWindow]
    }

    /// Sampled perceptual-hash distances per frame keyed by wall-clock seconds
    /// since the first frame. Detects regions of the recording where the same
    /// 500 ms window contains more than `changeThreshold` significant
    /// perceptual changes (a proxy for flicker / animation thrash).
    public static func detectAnimationThrash(
        sampledHashes: [(seconds: Double, hash: PerceptualHash)],
        windowSeconds: Double = 0.5,
        distanceThreshold: Int = 8,
        changeThreshold: Int = 3
    ) -> ThrashReport {
        guard sampledHashes.count >= 2 else {
            return ThrashReport(
                windowSeconds: windowSeconds,
                changeThreshold: changeThreshold,
                windows: []
            )
        }

        var changes: [Double] = []
        for index in 1..<sampledHashes.count {
            let previous = sampledHashes[index - 1]
            let current = sampledHashes[index]
            if previous.hash.distance(to: current.hash) > distanceThreshold {
                changes.append(current.seconds)
            }
        }

        var windows: [ThrashWindow] = []
        var pointer = 0
        for change in changes {
            let windowStart = change
            let windowEnd = change + windowSeconds
            var count = 0
            while pointer < changes.count, changes[pointer] < windowStart {
                pointer += 1
            }
            for laterChange in changes[pointer...] {
                if laterChange < windowEnd {
                    count += 1
                } else {
                    break
                }
            }
            if count > changeThreshold {
                windows.append(ThrashWindow(
                    startSeconds: windowStart,
                    endSeconds: windowEnd,
                    perceptualChanges: count
                ))
            }
        }
        return ThrashReport(
            windowSeconds: windowSeconds,
            changeThreshold: changeThreshold,
            windows: windows
        )
    }
}
