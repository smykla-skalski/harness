import HarnessMonitorKit
import SwiftUI

struct TaskBoardTriageRulesEditor: View {
  let store: HarnessMonitorStore
  let isActive: Bool

  @State private var state = TaskBoardTriageRulesEditorState()

  private var actions: TaskBoardTriageRulesEditorActions {
    TaskBoardTriageRulesEditorActions(store: store, state: state)
  }

  var body: some View {
    TaskBoardSection(title: "Triage Rules") {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        statusLine
        TextEditor(text: $state.draftText)
          .font(.system(.body, design: .monospaced))
          .frame(minHeight: 160, maxHeight: 260)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(HarnessMonitorTheme.controlBorder, lineWidth: 1)
          )
          .disabled(!actions.isWriteAuthorized)
          .accessibilityIdentifier("harness.task-board.triage-rules.editor")
        controlRow
        if let validation = state.validation, !validation.issues.isEmpty {
          validationIssuesList(validation.issues)
        }
        if let diff = state.previewDiff {
          previewDiffList(diff)
        }
        if !state.revisions.isEmpty {
          revisionsList
        }
        if !state.audit.isEmpty {
          auditList
        }
      }
    }
    .task(id: isActive) {
      guard isActive, !state.hasLoaded else { return }
      actions.load()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.triage-rules")
  }

  @ViewBuilder
  private var statusLine: some View {
    HStack {
      Text(activeRevisionText)
        .font(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Spacer()
      if let statusMessage = state.statusMessage {
        Text(statusMessage)
          .font(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .accessibilityIdentifier("harness.task-board.triage-rules.status")
      }
    }
  }

  private var activeRevisionText: String {
    if let activeRevision = state.activeRevision {
      "Active revision: \(activeRevision)"
    } else {
      "Active: BuiltInV1 default (no custom rules)"
    }
  }

  @ViewBuilder
  private var controlRow: some View {
    HStack {
      Button("Load") { actions.load() }
        .disabled(state.isBusy)
      Button("Preview") { actions.preview() }
        .disabled(state.isBusy)
      if actions.isWriteAuthorized {
        Button("Save Draft") { actions.saveDraft() }
          .disabled(state.isBusy)
        Button("Activate") { actions.activate() }
          .disabled(state.isBusy)
        Button("Deactivate") { actions.deactivate() }
          .disabled(state.isBusy || state.activeRevision == nil)
      } else {
        Text("Remote viewer access is read-only")
          .font(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .accessibilityIdentifier("harness.task-board.triage-rules.read-only")
      }
    }
  }

  @ViewBuilder
  private func validationIssuesList(_ issues: [TriageRuleSetValidationIssue]) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Validation issues (\(issues.count))")
        .font(.caption.weight(.semibold))
      ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
        Text("• \(issue.editorDescription)")
          .font(.caption)
      }
    }
    .accessibilityIdentifier("harness.task-board.triage-rules.validation")
  }

  @ViewBuilder
  private func previewDiffList(_ diff: [TriageRuleSetPreviewDiffEntry]) -> some View {
    let changed = diff.filter(\.governsPlacementChange)
    VStack(alignment: .leading, spacing: 2) {
      Text("Preview: \(changed.count) of \(diff.count) items would change")
        .font(.caption.weight(.semibold))
      ForEach(changed.prefix(20), id: \.itemId) { entry in
        Text(
          "• \(entry.itemId): \(entry.liveEffectiveVerdict?.editorDescription ?? "none") -> "
            + entry.candidateVerdict.editorDescription
        )
        .font(.caption)
      }
    }
    .accessibilityIdentifier("harness.task-board.triage-rules.preview-diff")
  }

  @ViewBuilder
  private var revisionsList: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Revision history")
        .font(.caption.weight(.semibold))
      ForEach(state.revisions.prefix(10), id: \.revision) { revision in
        Text(
          "• #\(revision.revision) \(revision.status.editorDescription) "
            + "(\(revision.ruleCount) rules) by \(revision.actor)"
        )
        .font(.caption)
      }
    }
    .accessibilityIdentifier("harness.task-board.triage-rules.revisions")
  }

  @ViewBuilder
  private var auditList: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Audit")
        .font(.caption.weight(.semibold))
      ForEach(state.audit.prefix(10), id: \.auditId) { entry in
        Text("• \(entry.kind.editorDescription) by \(entry.actor)")
          .font(.caption)
      }
    }
    .accessibilityIdentifier("harness.task-board.triage-rules.audit")
  }
}

extension TriageVerdict {
  fileprivate var editorDescription: String {
    switch self {
    case .todo: "todo"
    case .undecided: "undecided"
    }
  }
}

extension TriageRuleSetRevisionStatus {
  fileprivate var editorDescription: String { rawValue }
}

extension TriageRuleSetAuditKind {
  fileprivate var editorDescription: String { rawValue }
}

extension TriageRuleSetValidationIssue {
  fileprivate var editorDescription: String {
    switch self {
    case .unsupportedSchemaVersion(let expected, let actual):
      "unsupported schema version (expected \(expected), got \(actual))"
    case .tooManyRules(let max, let actual):
      "too many rules (max \(max), got \(actual))"
    case .malformedRuleId(let index):
      "malformed rule id at index \(index)"
    case .duplicateRuleId(let ruleId):
      "duplicate rule id '\(ruleId)'"
    case .tooManyConditions(let ruleId, let max, let actual):
      "rule '\(ruleId)' has too many conditions (max \(max), got \(actual))"
    case .malformedCondition(let ruleId, let conditionIndex):
      "rule '\(ruleId)' has a malformed condition at index \(conditionIndex)"
    case .duplicateSelector(let ruleId, let duplicateOf):
      "rule '\(ruleId)' duplicates the selector of '\(duplicateOf)'"
    case .selfContradictoryRule(let ruleId):
      "rule '\(ruleId)' can never match (self-contradictory)"
    case .shadowedRule(let ruleId, let shadowedBy):
      "rule '\(ruleId)' is unreachable (shadowed by '\(shadowedBy)')"
    }
  }
}
