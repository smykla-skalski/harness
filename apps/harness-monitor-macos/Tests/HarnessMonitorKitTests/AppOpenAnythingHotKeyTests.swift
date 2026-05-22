import Testing

@testable import HarnessMonitorKit

@Suite("AppOpenAnything hot key descriptor")
struct AppOpenAnythingHotKeyTests {
  @Test("Global hot key is disabled by default")
  func globalHotKeyIsDisabledByDefault() {
    #expect(OpenAnythingHotKeyDefaults.enabledDefault == false)
    #expect(OpenAnythingHotKeyDefaults.descriptorDefault == .defaultValue)
  }

  @Test("Default descriptor is Control Option Space")
  func defaultDescriptorIsControlOptionSpace() {
    let descriptor = OpenAnythingHotKeyDescriptor.defaultValue

    #expect(descriptor.keyCode == 49)
    #expect(descriptor.key == "Space")
    #expect(descriptor.modifiers == [.control, .option])
    #expect(descriptor.displayText == "⌃⌥Space")
    #expect(descriptor.isValid)
  }

  @Test("Descriptor round-trips through storage")
  func descriptorRoundTripsThroughStorage() throws {
    let descriptor = OpenAnythingHotKeyDescriptor(
      keyCode: 35,
      key: "P",
      modifiers: [.control, .option, .shift]
    )

    let decoded = try #require(OpenAnythingHotKeyDescriptor(storageValue: descriptor.storageValue))

    #expect(decoded == descriptor)
    #expect(OpenAnythingHotKeyDescriptor.decode(descriptor.storageValue) == descriptor)
  }

  @Test("Invalid descriptors are rejected")
  func invalidDescriptorsAreRejected() {
    let emptyKey = OpenAnythingHotKeyDescriptor(keyCode: 35, key: " ", modifiers: [.control])
    let noPrimaryModifier = OpenAnythingHotKeyDescriptor(
      keyCode: 35,
      key: "P",
      modifiers: [.shift]
    )
    let noKeyCode = OpenAnythingHotKeyDescriptor(keyCode: 0, key: "P", modifiers: [.command])

    #expect(!emptyKey.isValid)
    #expect(!noPrimaryModifier.isValid)
    #expect(!noKeyCode.isValid)
    #expect(OpenAnythingHotKeyDescriptor.decode(noPrimaryModifier.storageValue) == .defaultValue)
    #expect(OpenAnythingHotKeyDescriptor.decode("not|a|descriptor") == .defaultValue)
  }
}
