import Foundation

enum RefreshSnapshotErrorFormatting {
  static func describeUnderlying(
    _ error: any Error
  ) -> String {
    if let decodingError = error as? DecodingError {
      return describeDecodingError(decodingError)
    }
    return error.localizedDescription
  }

  private static func describeDecodingError(
    _ error: DecodingError
  ) -> String {
    switch error {
    case .dataCorrupted(let context):
      let path = describeCodingPath(context.codingPath)
      let description = context.debugDescription
      return
        "decoding failed at \(path): \(description)"
    case .keyNotFound(let key, let context):
      let path = describeCodingPath(context.codingPath + [key])
      let description = context.debugDescription
      return
        "missing key '\(key.stringValue)' at \(path): \(description)"
    case .typeMismatch(let type, let context):
      let path = describeCodingPath(context.codingPath)
      let description = context.debugDescription
      return
        "type mismatch for \(String(describing: type)) at \(path): \(description)"
    case .valueNotFound(let type, let context):
      let path = describeCodingPath(context.codingPath)
      let description = context.debugDescription
      return
        "missing \(String(describing: type)) at \(path): \(description)"
    @unknown default:
      return error.localizedDescription
    }
  }

  private static func describeCodingPath(_ codingPath: [CodingKey]) -> String {
    guard !codingPath.isEmpty else {
      return "root"
    }

    var rendered = ""
    for key in codingPath {
      if let index = key.intValue {
        rendered += "[\(index)]"
      } else if rendered.isEmpty {
        rendered = key.stringValue
      } else {
        rendered += ".\(key.stringValue)"
      }
    }
    return rendered
  }
}
