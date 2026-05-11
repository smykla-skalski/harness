import Foundation
import SwiftData

public actor SessionCacheService {
  enum MetadataUpdate: Sendable {
    case refresh
    case advance(insertedSessionCount: Int)
  }

  struct WriteResult: Sendable {
    let didPersist: Bool
    let metadataUpdate: MetadataUpdate
  }

  let modelContainer: ModelContainer
  let databaseURL: URL?
  let beforeSave: () async throws -> Void
  let saveChanges: (ModelContext) throws -> Void

  public init(
    modelContainer: ModelContainer,
    databaseURL: URL? = nil,
    beforeSave: @escaping @Sendable () async throws -> Void = {},
    saveChanges: @escaping @Sendable (ModelContext) throws -> Void = { context in
      try context.save()
    }
  ) {
    self.modelContainer = modelContainer
    self.databaseURL = databaseURL
    self.beforeSave = beforeSave
    self.saveChanges = saveChanges
  }

  struct SessionMetadata: Sendable {
    let count: Int
    let lastCachedAt: Date?
  }

  struct CachedSessionSnapshot: Sendable {
    let detail: SessionDetail
    let timeline: [TimelineEntry]
    let timelineWindow: TimelineWindowResponse?
    let transcript: [TimelineEntry]?
    let transcriptSource: HarnessMonitorSessionWindowTranscriptSource?

    init(
      detail: SessionDetail,
      timeline: [TimelineEntry],
      timelineWindow: TimelineWindowResponse?,
      transcript: [TimelineEntry]? = nil,
      transcriptSource: HarnessMonitorSessionWindowTranscriptSource? = nil
    ) {
      self.detail = detail
      self.timeline = timeline
      self.timelineWindow = timelineWindow
      self.transcript = transcript
      self.transcriptSource = transcriptSource
    }
  }

  func makeContext() -> ModelContext {
    let context = ModelContext(modelContainer)
    context.autosaveEnabled = false
    return context
  }

}
