import Foundation

// Wire map for the reviews local-clone progress push payload. The generated wire is an
// internally-tagged enum; the hand ReviewLocalCloneProgress flattens it into a struct with a kind
// discriminator and per-variant optional fields.

extension ReviewLocalCloneProgress.Operation {
  init(wire: LocalCloneOperationWire) {
    switch wire {
    case .clone: self = .clone
    case .fetch: self = .fetch
    }
  }
}

extension ReviewLocalCloneProgress {
  init(wire: LocalCloneProgressEventPayloadWire) {
    switch wire {
    case .started(let repoFullName, let operation):
      self.init(
        kind: .started,
        repoFullName: repoFullName,
        operation: Operation(wire: operation),
        durationMillis: nil,
        message: nil
      )
    case .completed(let repoFullName, let operation, let durationMillis):
      self.init(
        kind: .completed,
        repoFullName: repoFullName,
        operation: Operation(wire: operation),
        durationMillis: durationMillis,
        message: nil
      )
    case .failed(let repoFullName, let operation, let message):
      self.init(
        kind: .failed,
        repoFullName: repoFullName,
        operation: Operation(wire: operation),
        durationMillis: nil,
        message: message
      )
    }
  }
}
