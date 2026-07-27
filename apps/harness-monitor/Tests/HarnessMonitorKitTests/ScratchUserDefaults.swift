import Foundation

/// A throwaway defaults domain for one test. Held by the suite value, so the
/// domain is removed as soon as that test's suite instance goes away and a
/// stored value can never leak into the app's own preferences or into the next
/// test. Construction fails loudly rather than falling back to `.standard`.
final class ScratchUserDefaults {
  struct Unavailable: Error {
    let suiteName: String
  }

  let suiteName: String
  let userDefaults: UserDefaults

  init(label: String) throws {
    let suiteName = "io.harnessmonitor.tests.\(label).\(UUID().uuidString)"
    guard let userDefaults = UserDefaults(suiteName: suiteName) else {
      throw Unavailable(suiteName: suiteName)
    }
    self.suiteName = suiteName
    self.userDefaults = userDefaults
  }

  deinit {
    UserDefaults().removePersistentDomain(forName: suiteName)
  }
}
