import SwiftData
import Testing

@discardableResult
@MainActor
func assertSwiftDataRoundTrip<C: PersistentModel, T: Equatable>(
  _ original: T,
  cache: (T) -> C,
  restore: (C) -> T,
  container: ModelContainer,
  sourceLocation: SourceLocation = #_sourceLocation
) throws -> T {
  let cached = cache(original)
  container.mainContext.insert(cached)
  try container.mainContext.save()
  let fetched = try container.mainContext.fetch(FetchDescriptor<C>())
  let match = try #require(fetched.first, sourceLocation: sourceLocation)
  let restored = restore(match)
  #expect(restored == original, sourceLocation: sourceLocation)
  return restored
}
