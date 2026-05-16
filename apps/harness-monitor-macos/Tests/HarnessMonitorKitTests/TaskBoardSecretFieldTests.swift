import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("TaskBoardSecretField materialization")
struct TaskBoardSecretFieldTests {
  @Test(".notConfigured materializes to nil regardless of loaded value")
  func notConfiguredAlwaysReturnsNil() {
    let field = TaskBoardSecretField.notConfigured
    #expect(field.materialized(loaded: nil) == nil)
    #expect(field.materialized(loaded: "secret-on-keychain") == nil)
  }

  @Test(".configured re-uses the loaded value so untouched secrets survive save")
  func configuredEchoesLoadedValue() {
    let field = TaskBoardSecretField.configured
    #expect(field.materialized(loaded: "secret-on-keychain") == "secret-on-keychain")
    #expect(field.materialized(loaded: nil) == nil)
  }

  @Test(".editing trims whitespace and treats empty as nil")
  func editingTrimsAndNormalizes() {
    #expect(TaskBoardSecretField.editing("  new-value  ").materialized(loaded: nil) == "new-value")
    #expect(TaskBoardSecretField.editing("   ").materialized(loaded: "stale") == nil)
  }

  @Test("secretFromLoaded maps presence to .configured, absence to .notConfigured")
  func secretFromLoadedRoundTrips() {
    #expect(TaskBoardSecretField.secretFromLoaded(nil) == .notConfigured)
    #expect(TaskBoardSecretField.secretFromLoaded("") == .notConfigured)
    #expect(TaskBoardSecretField.secretFromLoaded("anything") == .configured)
  }
}
