import Testing

@testable import HarnessMonitorKit

@Suite("OpenAnything corpus signature")
struct OpenAnythingCorpusSignatureTests {
  @Test("Same records produce identical signatures")
  func sameRecordsProduceIdenticalSignatures() {
    let records = [
      Self.record(id: "a", title: "Alpha"),
      Self.record(id: "b", title: "Beta"),
    ]

    let first = OpenAnythingCorpusSignature.compute(records)
    let second = OpenAnythingCorpusSignature.compute(records)

    #expect(first == second)
  }

  @Test("Changing any record field changes the signature")
  func changingFieldsChangesSignature() {
    let base = [
      Self.record(id: "a", title: "Alpha"),
      Self.record(id: "b", title: "Beta"),
    ]
    let titleChanged = [
      Self.record(id: "a", title: "Alpha Updated"),
      Self.record(id: "b", title: "Beta"),
    ]
    let subtitleChanged = [
      Self.record(id: "a", title: "Alpha", subtitle: "Subtitle"),
      Self.record(id: "b", title: "Beta"),
    ]
    let searchBodyChanged = [
      Self.record(id: "a", title: "Alpha", searchBodyParts: ["extra"]),
      Self.record(id: "b", title: "Beta"),
    ]

    let baseSignature = OpenAnythingCorpusSignature.compute(base)

    #expect(baseSignature != OpenAnythingCorpusSignature.compute(titleChanged))
    #expect(baseSignature != OpenAnythingCorpusSignature.compute(subtitleChanged))
    #expect(baseSignature != OpenAnythingCorpusSignature.compute(searchBodyChanged))
  }

  @Test("Empty corpus and single-record corpus disagree")
  func emptyAndSingleRecordDisagree() {
    let empty: [OpenAnythingRecord] = []
    let single = [Self.record(id: "a", title: "Alpha")]

    #expect(
      OpenAnythingCorpusSignature.compute(empty)
        != OpenAnythingCorpusSignature.compute(single)
    )
  }

  @Test("Record order affects the signature")
  func orderAffectsSignature() {
    let forward = [
      Self.record(id: "a", title: "Alpha"),
      Self.record(id: "b", title: "Beta"),
    ]
    let reversed = [
      Self.record(id: "b", title: "Beta"),
      Self.record(id: "a", title: "Alpha"),
    ]

    #expect(
      OpenAnythingCorpusSignature.compute(forward)
        != OpenAnythingCorpusSignature.compute(reversed)
    )
  }

  private static func record(
    id: String,
    title: String,
    subtitle: String? = nil,
    searchBodyParts: [String?] = []
  ) -> OpenAnythingRecord {
    OpenAnythingRecord(
      id: id,
      domain: .actions,
      target: .action(.refresh),
      title: title,
      subtitle: subtitle,
      searchBodyParts: searchBodyParts
    )
  }
}
