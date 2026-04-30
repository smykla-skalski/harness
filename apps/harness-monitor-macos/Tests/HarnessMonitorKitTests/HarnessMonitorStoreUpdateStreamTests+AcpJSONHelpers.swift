@testable import HarnessMonitorKit

func jsonObject(from value: JSONValue?) -> [String: JSONValue]? {
  guard case .object(let object)? = value else {
    return nil
  }
  return object
}

func jsonString(from value: JSONValue?) -> String? {
  guard case .string(let string)? = value else {
    return nil
  }
  return string
}

func jsonNumber(from value: JSONValue?) -> UInt64? {
  guard case .number(let number)? = value, number >= 0 else {
    return nil
  }
  return UInt64(number)
}
