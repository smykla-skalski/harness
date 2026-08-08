import Foundation

extension HarnessMonitorAPIClient {
  /// Percent-encodes one task-board identifier for use as a single URL path
  /// segment, refusing anything that could escape it.
  ///
  /// Every task-board endpoint that interpolates an id needs this, and each one
  /// used to carry its own private copy. One copy means one place to fix if the
  /// allowed set ever has to change.
  func taskBoardPathSegment(_ value: String) throws -> String {
    guard
      !value.isEmpty,
      !value.contains("/"),
      !value.contains("\\"),
      !value.contains("..")
    else {
      throw HarnessMonitorAPIError.invalidEndpoint(value)
    }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
      throw HarnessMonitorAPIError.invalidEndpoint(value)
    }
    return encoded
  }
}
