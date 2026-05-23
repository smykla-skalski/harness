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

  @Test("Descriptor round-trips when key contains a pipe character")
  func descriptorRoundTripsWithPipeInKey() throws {
    let descriptor = OpenAnythingHotKeyDescriptor(
      keyCode: 42,
      key: "|",
      modifiers: [.command, .shift]
    )

    let storage = descriptor.storageValue
    let decoded = try #require(OpenAnythingHotKeyDescriptor(storageValue: storage))

    #expect(decoded == descriptor)
    #expect(decoded.key == "|")
  }

  @Test("Descriptor preserves keys containing multiple pipes verbatim")
  func descriptorPreservesMultiplePipes() throws {
    let descriptor = OpenAnythingHotKeyDescriptor(
      keyCode: 42,
      key: "a|b|c",
      modifiers: [.command]
    )

    let decoded = try #require(OpenAnythingHotKeyDescriptor(storageValue: descriptor.storageValue))
    #expect(decoded.key == "a|b|c")
    #expect(decoded == descriptor)
  }

  @Test("Decode returns default for nil and obviously malformed input")
  func decodeReturnsDefaultForMalformedInput() {
    #expect(OpenAnythingHotKeyDescriptor.decode(nil) == .defaultValue)
    #expect(OpenAnythingHotKeyDescriptor.decode("") == .defaultValue)
    #expect(OpenAnythingHotKeyDescriptor.decode("garbage") == .defaultValue)
    #expect(OpenAnythingHotKeyDescriptor.decode("1|2") == .defaultValue)
  }

  @Test("Modifier bit capacity is documented as UInt8 wide")
  func modifierBitCapacityMatchesStorage() {
    #expect(OpenAnythingHotKeyModifiers.bitCapacity == 8)
    // All currently defined cases must fit inside the documented capacity.
    let highBit = max(
      OpenAnythingHotKeyModifiers.control.rawValue,
      OpenAnythingHotKeyModifiers.option.rawValue,
      OpenAnythingHotKeyModifiers.command.rawValue,
      OpenAnythingHotKeyModifiers.shift.rawValue
    )
    #expect(Int(highBit) < (1 << OpenAnythingHotKeyModifiers.bitCapacity))
  }

  // MARK: - carbonFlags conversion (#57)

  // Carbon constants from `Carbon/Events.h`:
  //   cmdKey     = 1 << 8  = 256
  //   shiftKey   = 1 << 9  = 512
  //   optionKey  = 1 << 11 = 2048
  //   controlKey = 1 << 12 = 4096
  // Tests pin the conversion against those values so a future tweak to either
  // side has to update both.

  @Test("Empty modifier set converts to zero Carbon flags")
  func carbonFlagsEmpty() {
    #expect(OpenAnythingHotKeyModifiers().carbonFlags == 0)
  }

  @Test("Single-modifier sets map to their Carbon bits")
  func carbonFlagsSingleModifiers() {
    #expect(OpenAnythingHotKeyModifiers([.command]).carbonFlags == 256)
    #expect(OpenAnythingHotKeyModifiers([.shift]).carbonFlags == 512)
    #expect(OpenAnythingHotKeyModifiers([.option]).carbonFlags == 2048)
    #expect(OpenAnythingHotKeyModifiers([.control]).carbonFlags == 4096)
  }

  @Test("Multi-modifier sets OR their Carbon bits together")
  func carbonFlagsCombinations() {
    let controlOption = OpenAnythingHotKeyModifiers([.control, .option])
    #expect(controlOption.carbonFlags == 4096 | 2048)

    let commandShift = OpenAnythingHotKeyModifiers([.command, .shift])
    #expect(commandShift.carbonFlags == 256 | 512)

    let allFour = OpenAnythingHotKeyModifiers([.control, .option, .command, .shift])
    #expect(allFour.carbonFlags == 4096 | 2048 | 256 | 512)
  }

  @Test("Default descriptor produces Control+Option Carbon flags")
  func carbonFlagsDefaultDescriptor() {
    let flags = OpenAnythingHotKeyDescriptor.defaultValue.modifiers.carbonFlags
    #expect(flags == 4096 | 2048)
  }
}
