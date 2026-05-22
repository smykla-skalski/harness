import Foundation

/// Names of payload keys that must be masked when emitted to the audit timeline. Case-insensitive
/// matching is the consumer's responsibility; lookups should fold to lowercase before comparing.
public enum SupervisorAuditSensitiveKeys {
  /// Lowercase key set shared by string-pattern redaction and JSON payload redaction.
  public static let names: Set<String> = [
    "token",
    "secret",
    "password",
    "api_key",
    "authorization",
    "auth",
  ]

  /// Prefixes that identify provider-issued credentials inside string values, even when the
  /// surrounding key is not in `names`.
  public static let valuePrefixes: [String] = [
    "xox",
    "ghp_",
    "ghs_",
    "gho_",
    "ghr_",
    "sk-",
    "pat_",
  ]

  /// Placeholder substituted for any matched value.
  public static let redactionPlaceholder = "[redacted]"
}

/// Walks a payload JSON document and masks the values of sensitive keys plus string values that
/// match a known provider prefix. Returns the input unchanged when JSON parsing fails — the audit
/// pipeline must never refuse to render a row because its payload could not be parsed.
public func redactSupervisorPayloadJSON(_ raw: String) -> String {
  guard let data = raw.data(using: .utf8) else {
    return raw
  }
  guard
    let parsed = try? JSONSerialization.jsonObject(
      with: data,
      options: [.fragmentsAllowed]
    )
  else {
    return raw
  }
  let redacted = redactJSONValue(parsed)
  guard
    let output = try? JSONSerialization.data(
      withJSONObject: redacted,
      options: [.fragmentsAllowed]
    ),
    let text = String(data: output, encoding: .utf8)
  else {
    return raw
  }
  return text
}

private func redactJSONValue(_ value: Any) -> Any {
  switch value {
  case let dict as [String: Any]:
    var output: [String: Any] = [:]
    output.reserveCapacity(dict.count)
    for (key, child) in dict {
      if SupervisorAuditSensitiveKeys.names.contains(key.lowercased()) {
        output[key] = SupervisorAuditSensitiveKeys.redactionPlaceholder
      } else {
        output[key] = redactJSONValue(child)
      }
    }
    return output
  case let array as [Any]:
    return array.map(redactJSONValue)
  case let string as String:
    return redactSensitiveStringValue(string)
  default:
    return value
  }
}

private func redactSensitiveStringValue(_ string: String) -> Any {
  for prefix in SupervisorAuditSensitiveKeys.valuePrefixes where string.hasPrefix(prefix) {
    return SupervisorAuditSensitiveKeys.redactionPlaceholder
  }
  return string
}
