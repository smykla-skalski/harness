import Foundation

// Wire map for the task-board working-copy obtain progress push payload. The generated wire is an
// internally-tagged enum; the hand TaskBoardWorkingCopyProgress flattens it into a struct with a
// kind discriminator and per-variant optional fields.

extension TaskBoardWorkingCopyProgress {
  init(wire: WorkingCopyProgressEventPayloadWire) {
    switch wire {
    case .started(let repoFullName):
      self.init(kind: .started, repoFullName: repoFullName)
    case .advanced(let repoFullName, let phase, let done, let total, let blocked):
      self.init(
        kind: .advanced,
        repoFullName: repoFullName,
        phase: phase,
        done: done,
        total: total,
        blocked: blocked
      )
    case .completed(let repoFullName, let durationMillis):
      self.init(
        kind: .completed,
        repoFullName: repoFullName,
        durationMillis: durationMillis
      )
    case .failed(let repoFullName, let message):
      self.init(kind: .failed, repoFullName: repoFullName, message: message)
    }
  }
}
