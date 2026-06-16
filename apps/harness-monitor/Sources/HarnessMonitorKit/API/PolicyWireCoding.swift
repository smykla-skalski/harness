import Foundation

/// JSON coder for the policy-graph wire surface (the policy document and every
/// response that carries one).
///
/// The generated `PolicyGraph*` node-kind payload types spell explicit
/// snake_case `CodingKeys` (`case reasonCodes = "reason_codes"`,
/// `case fromNode = "from_node"`, ...). That is mutually exclusive with
/// `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`: the strategy first
/// rewrites the JSON key `reason_codes` to `reasonCodes`, then matches it against
/// the coding key's literal string value `reason_codes` and finds no match, so the
/// decode throws `keyNotFound`. The shared daemon decoder uses
/// `.convertFromSnakeCase` for every other response, so the policy subtree gets a
/// dedicated decoder with no key strategy instead: every wire type in the subtree
/// already spells its own snake keys, and the daemon emits uniform snake_case, so
/// plain decoding matches it byte-for-byte.
///
/// Encoding still goes through the shared `.convertToSnakeCase` encoder: that
/// strategy is idempotent on already-snake coding keys, so request bodies and
/// cache blobs round-trip unchanged.
public enum PolicyWireCoding {
  public static let decoder = JSONDecoder()
}
