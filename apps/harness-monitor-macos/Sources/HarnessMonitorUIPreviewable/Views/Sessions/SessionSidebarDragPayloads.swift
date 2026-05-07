import SwiftUI
import UniformTypeIdentifiers

struct SessionAgentDragPayload: Codable, Transferable {
  let sessionID: String
  let agentID: String

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .harnessMonitorSessionAgent)
  }
}

extension UTType {
  static let harnessMonitorSessionAgent = UTType(
    exportedAs: "io.harnessmonitor.session-agent",
    conformingTo: .json
  )
}
