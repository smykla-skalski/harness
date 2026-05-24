import Foundation
import HarnessMonitorKit

/// UserDefaults keys + stable JSON round-trip for `AuditTimelineFilterState`.
public enum AuditTimelineFilterDefaults {
  public static let filtersKey = "supervisor.audit.filters"
}

extension AuditTimelineFilterState {
  // MARK: - Hydration / persistence

  /// Restore from UserDefaults. Called by `init`; safe to call again to force
  /// a re-read (e.g. tests that mutate the defaults bucket directly).
  public func hydrate() {
    guard let raw = userDefaults.string(forKey: storageKey) else { return }
    guard let decoded = Self.decodeFilters(from: raw) else { return }
    if decoded != filters {
      filters = decoded
    }
  }

  /// Persist the current filter snapshot. Triggered on every setter via
  /// `didSet`; can also be called directly if external mutation bypasses the
  /// observed `filters` property.
  public func persist() {
    if filters.isEmpty {
      userDefaults.removeObject(forKey: storageKey)
      return
    }
    guard let encoded = Self.encodeFilters(filters) else { return }
    userDefaults.set(encoded, forKey: storageKey)
  }

  // MARK: - Codec

  /// Compact storage shape. Sets become sorted string arrays, severities use
  /// their `rawValue`, and the date range serializes via the shared
  /// ISO8601 formatter.
  struct Storage: Codable, Equatable {
    let ruleIDs: [String]
    let kinds: [String]
    let severities: [String]
    let dateRangeStart: String?
    let dateRangeEnd: String?
    let searchText: String
    let decisionID: String?
  }

  static func encodeFilters(_ filters: SupervisorAuditFilters) -> String? {
    let storage = Storage(
      ruleIDs: filters.ruleIDs.sorted(),
      kinds: filters.kinds.map(\.rawValue).sorted(),
      severities: filters.severities.map(\.rawValue).sorted(),
      dateRangeStart: filters.dateRange.map { Self.formatter.string(from: $0.lowerBound) },
      dateRangeEnd: filters.dateRange.map { Self.formatter.string(from: $0.upperBound) },
      searchText: filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines),
      decisionID: filters.decisionID?.uuidString
    )
    guard let data = try? Self.encoder.encode(storage) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func decodeFilters(from raw: String) -> SupervisorAuditFilters? {
    guard
      !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let data = raw.data(using: .utf8),
      let storage = try? Self.decoder.decode(Storage.self, from: data)
    else {
      return nil
    }

    let kinds = Set(storage.kinds.compactMap(SupervisorEvent.Kind.init(rawValue:)))
    let severities = Set(storage.severities.compactMap(DecisionSeverity.init(rawValue:)))
    let dateRange: ClosedRange<Date>?
    if let startRaw = storage.dateRangeStart,
      let endRaw = storage.dateRangeEnd,
      let start = Self.formatter.date(from: startRaw),
      let end = Self.formatter.date(from: endRaw),
      start <= end
    {
      dateRange = start...end
    } else {
      dateRange = nil
    }
    let decisionID = storage.decisionID.flatMap(UUID.init(uuidString:))

    return SupervisorAuditFilters(
      ruleIDs: Set(storage.ruleIDs),
      kinds: kinds,
      severities: severities,
      dateRange: dateRange,
      searchText: storage.searchText,
      decisionID: decisionID
    )
  }

  // Encoder/decoder/formatter live as static lets so view bodies and setters
  // never allocate them. `outputFormatting = .sortedKeys` keeps the persisted
  // blob stable for equality-based tests.
  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  static let decoder = JSONDecoder()

  // `ISO8601DateFormatter` is thread-safe for read-only use after configuration
  // (Apple's docs allow concurrent calls to `string(from:)` / `date(from:)`),
  // but the type is not `Sendable`. The `nonisolated(unsafe)` annotation is
  // safe here because we only read these methods and never mutate the
  // configuration after the closure returns.
  nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
}
