import HarnessMonitorKit

/// Commit entry points for the `evidence_check` checks-array editor. An
/// evidence node holds an ordered list of checks; the engine fails on the
/// first check whose predicate does not hold and emits that check's
/// `failReasonCode`, so the array order is the failure priority and the codes
/// are exactly what downstream fan-in branches route on. Every mutation flows
/// through `commitPolicyKindMutation` so it lands as one undo step and no-ops
/// when nothing changed. Each closure guards its index and the
/// `evidence_check` kind, so a stale inspector call is a quiet no-op rather
/// than a crash or a phantom undo entry.
extension PolicyCanvasViewModel {
  /// Append a check to the selected evidence node. The new check defaults to a
  /// passing green-checks predicate with a valid fail/missing reason code so an
  /// author can refine it rather than start from an invalid daemon token.
  func addSelectedEvidenceCheck() {
    commitPolicyKindMutation { kind in
      guard kind.kind == "evidence_check" else { return }
      kind.checks.append(
        TaskBoardPolicyEvidenceCheck(
          field: .checksGreen,
          pass: TaskBoardPolicyEvidencePredicate(predicate: .isTrue),
          failReasonCode: PolicyCanvasReasonCode.checksNotGreen,
          missingReasonCode: PolicyCanvasReasonCode.missingMergeEvidence
        )
      )
    }
  }

  /// Remove the check at `index`. The array never empties: an evidence_check
  /// with no checks passes everything, which would silently neuter the node.
  func removeSelectedEvidenceCheck(at index: Int) {
    commitPolicyKindMutation { kind in
      guard kind.kind == "evidence_check",
        kind.checks.indices.contains(index),
        kind.checks.count > 1
      else {
        return
      }
      kind.checks.remove(at: index)
    }
  }

  /// Move a check from one slot to another. Because order is the failure
  /// priority, this is the priority control - dragging a check up makes it win
  /// the reason code over checks below it.
  func moveSelectedEvidenceCheck(from source: Int, to destination: Int) {
    commitPolicyKindMutation { kind in
      guard kind.kind == "evidence_check",
        source != destination,
        kind.checks.indices.contains(source),
        kind.checks.indices.contains(destination)
      else {
        return
      }
      let check = kind.checks.remove(at: source)
      kind.checks.insert(check, at: destination)
    }
  }

  /// Commit an evidence field pick for the check at `index`.
  func commitSelectedEvidenceCheckField(
    _ field: TaskBoardPolicyEvidenceField,
    at index: Int
  ) {
    commitPolicyKindMutation { kind in
      guard kind.kind == "evidence_check", kind.checks.indices.contains(index) else { return }
      kind.checks[index].field = field
    }
  }

  /// Commit the pass predicate for the check at `index`. The check passes when
  /// the field satisfies this predicate; otherwise the fail reason code fires.
  func commitSelectedEvidenceCheckPredicate(
    _ predicate: TaskBoardPolicyEvidencePredicateValue,
    at index: Int
  ) {
    commitPolicyKindMutation { kind in
      guard kind.kind == "evidence_check", kind.checks.indices.contains(index) else { return }
      kind.checks[index].pass = TaskBoardPolicyEvidencePredicate(predicate: predicate)
    }
  }

  /// Commit the fail reason code for the check at `index`. This is the code the
  /// engine emits when the check fails, and the failure type a fan-in branch
  /// can be routed on.
  func commitSelectedEvidenceCheckFailReasonCode(
    _ reasonCode: String,
    at index: Int
  ) {
    commitPolicyKindMutation { kind in
      guard kind.kind == "evidence_check", kind.checks.indices.contains(index) else { return }
      kind.checks[index].failReasonCode = reasonCode
    }
  }
}
