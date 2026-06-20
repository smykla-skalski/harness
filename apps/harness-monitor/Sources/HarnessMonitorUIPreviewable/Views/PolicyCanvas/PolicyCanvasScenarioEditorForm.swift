import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels
import SwiftUI

/// The scenario editor body: identity (name + action + workflow), subject, and
/// evidence sections, all bound to the sheet-owned draft. Optional evidence stays
/// "Any" until the user picks Yes/No, so a scenario only constrains what it names.
struct PolicyCanvasScenarioEditorForm: View {
  @Binding var draft: PolicyCanvasScenarioEditorDraft

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      identitySection
      subjectSection
      evidenceSection
    }
  }

  private var identitySection: some View {
    section("Scenario") {
      labeledField("Name") {
        TextField("e.g. Merge - checks green", text: $draft.name)
          .textFieldStyle(.roundedBorder)
      }
      labeledField("Action") {
        Picker("Action", selection: $draft.action) {
          ForEach(PolicyAction.allCases) { action in
            Text(action.policyCanvasTitle).tag(action)
          }
        }
        .labelsHidden()
      }
      labeledField("Workflow") {
        TextField("Optional workflow id", text: $draft.workflow)
          .textFieldStyle(.roundedBorder)
      }
    }
  }

  private var subjectSection: some View {
    section("Subject") {
      labeledField("Repository") { plainField("owner/repo", $draft.repository) }
      labeledField("Branch") { plainField("feature/...", $draft.branch) }
      labeledField("Pull request") { plainField("123", $draft.pullRequest) }
      labeledField("Task item") { plainField("task id", $draft.taskBoardItemId) }
      labeledField("Session") { plainField("session id", $draft.sessionId) }
      labeledField("Agent") { plainField("agent id", $draft.agentId) }
      labeledField("Paths") {
        TextField("one path per line", text: $draft.paths, axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .lineLimit(2...4)
      }
    }
  }

  private var evidenceSection: some View {
    section("Evidence") {
      triStateRow("Checks green", $draft.checksGreen)
      triStateRow("Branch protection allows merge", $draft.branchProtectionAllowsMerge)
      triStateRow("Reviewer approved", $draft.reviewerVerdictApproved)
      labeledField("Unresolved requested changes") {
        plainField("0", $draft.unresolvedRequestedChanges)
      }
      triStateRow("Protected path touched", $draft.protectedPathTouched)
      labeledField("Risk score") { plainField("0-255", $draft.riskScore) }
      triStateRow("Review is open", $draft.reviewIsOpen)
      triStateRow("Review is draft", $draft.reviewIsDraft)
      triStateRow("Review required", $draft.reviewReviewRequired)
      triStateRow("Review has no decision", $draft.reviewHasNoDecision)
      triStateRow("Review has merge conflicts", $draft.reviewHasMergeConflicts)
      triStateRow("Review policy blocked", $draft.reviewPolicyBlocked)
      triStateRow("Viewer can update", $draft.reviewViewerCanUpdate)
    }
  }

  private func section(
    _ title: String,
    @ViewBuilder content: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
      content()
    }
  }

  private func labeledField(
    _ label: String,
    @ViewBuilder control: () -> some View
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label)
        .scaledFont(.caption)
        .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
        .frame(width: 180, alignment: .leading)
      control()
    }
  }

  private func plainField(_ prompt: String, _ value: Binding<String>) -> some View {
    TextField(prompt, text: value)
      .textFieldStyle(.roundedBorder)
  }

  private func triStateRow(_ label: String, _ value: Binding<ScenarioTriState>) -> some View {
    labeledField(label) {
      Picker(label, selection: value) {
        ForEach(ScenarioTriState.allCases) { state in
          Text(state.label).tag(state)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
    }
  }
}
