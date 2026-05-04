import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Standard error warning capture")
struct HarnessMonitorStandardErrorWarningCaptureTests {
  @Test("Matcher mirrors AttributeGraph warning lines")
  func matcherMirrorsAttributeGraphWarnings() {
    let message = HarnessMonitorSwiftUIWarningMatcher.mirroredLogMessage(
      for: "=== AttributeGraph: cycle detected through attribute 6609432 ==="
    )

    #expect(
      message == "AttributeGraph: cycle detected through attribute 6609432"
    )
  }

  @Test("Matcher mirrors FocusedValue warning lines")
  func matcherMirrorsFocusedValueWarnings() {
    let message = HarnessMonitorSwiftUIWarningMatcher.mirroredLogMessage(
      for: "FocusedValue update tried to update multiple times per frame"
    )

    #expect(
      message == "FocusedValue update tried to update multiple times per frame"
    )
  }

  @Test("Matcher ignores unrelated stderr lines")
  func matcherIgnoresUnrelatedWarnings() {
    #expect(
      HarnessMonitorSwiftUIWarningMatcher.mirroredLogMessage(
        for: "agent bridge disconnected"
      ) == nil
    )
  }

  @Test("Matcher ignores OSLog transport echo lines")
  func matcherIgnoresOSLogTransportEchoLines() {
    let oslogEchoLine =
      "OSLOG-122EEBC2-704E-403D-BDBF-F7E973D2B7F1 7 80 L 27 {t:1777881608.865679}"
      + "\tAttributeGraph: cycle detected through attribute 5837592"
    #expect(HarnessMonitorSwiftUIWarningMatcher.mirroredLogMessage(for: oslogEchoLine) == nil)
  }

  @Test("Matcher ignores already formatted SwiftUI warning lines")
  func matcherIgnoresAlreadyFormattedWarningLines() {
    #expect(
      HarnessMonitorSwiftUIWarningMatcher.mirroredLogMessage(
        for: "SwiftUI runtime warning: AttributeGraph: cycle detected through attribute 5837592"
      ) == nil
    )
  }

  @Test("Line splitter reassembles chunked stderr lines across CRLF boundaries")
  func lineSplitterReassemblesChunks() {
    var splitter = HarnessMonitorBufferedLineSplitter()

    let firstChunk = splitter.append(
      Data("=== AttributeGraph: cycle detected".utf8)
    )
    let secondChunk = splitter.append(
      Data(" through attribute 4409624 ===\r\nplain stderr line\r\n".utf8)
    )

    #expect(firstChunk.isEmpty)
    #expect(
      secondChunk
        == [
          "=== AttributeGraph: cycle detected through attribute 4409624 ===",
          "plain stderr line",
        ]
    )
  }
}
