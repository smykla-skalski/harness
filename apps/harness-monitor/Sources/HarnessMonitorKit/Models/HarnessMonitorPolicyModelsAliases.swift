import HarnessMonitorPolicyModels

// The pipeline simulate-response cluster stays hand-authored in
// HarnessMonitorPolicyModels: these types carry app-only shape the generated
// Rust wire types do not model (synthesized `isValid`, a lenient
// `ValidationIssue` that also represents client-local preflight codes, and the
// simulate response envelope). They are surfaced into the Kit namespace here so
// callers reach them without importing the models module directly.
public typealias TaskBoardPolicyPipelineValidation =
  HarnessMonitorPolicyModels.TaskBoardPolicyPipelineValidation
public typealias TaskBoardPolicyPipelineValidationIssue =
  HarnessMonitorPolicyModels.TaskBoardPolicyPipelineValidationIssue
public typealias TaskBoardPolicyDecision = HarnessMonitorPolicyModels.TaskBoardPolicyDecision
public typealias TaskBoardPolicyPipelineSimulatedDecision =
  HarnessMonitorPolicyModels.TaskBoardPolicyPipelineSimulatedDecision
public typealias TaskBoardPolicyPipelineSimulationResult =
  HarnessMonitorPolicyModels.TaskBoardPolicyPipelineSimulationResult

// The generated simulate/audit wire types own the daemon snake_case decode; the
// API client and audit mapping decode these through the plain decoder then map to
// the hand models above. Surface them into Kit so those call sites reach them
// without importing the models module directly.
public typealias PolicyPipelineSimulationResultWire =
  HarnessMonitorPolicyModels.PolicyPipelineSimulationResultWire
public typealias PolicyPipelineAuditSummaryWire =
  HarnessMonitorPolicyModels.PolicyPipelineAuditSummaryWire

// The generated task-board canvas wire types name PolicyGraphMode as a stored
// property type, so it must resolve from the Kit namespace. The mode rawValue
// bridges to the hand TaskBoardPolicyPipelineMode in the +Wire mapping.
public typealias PolicyGraphMode = HarnessMonitorPolicyModels.PolicyGraphMode

// The generated canvas workspace wire type names PolicyScenario in its scenarios
// array, so it must resolve from the Kit namespace too.
public typealias PolicyScenario = HarnessMonitorPolicyModels.PolicyScenario

// The go-live decision diff is pure data (per-scenario live-vs-draft verdicts),
// so the API client decodes the generated wire type directly the way the
// simulate result wire is consumed, rather than through a hand model. Surfaced
// into Kit under a distinct `TaskBoard…` name (not the bare generated name) so
// the client/store/runtime reach it without importing the models module, and so
// view files that import BOTH modules can name it without a lookup clash against
// the generated `PolicyPipelineGoLiveDiff`. Its `diffs` entries stay the
// generated `PolicyPipelineGoLiveDiffEntry`, resolved from the models module.
public typealias TaskBoardPolicyPipelineGoLiveDiff =
  HarnessMonitorPolicyModels.PolicyPipelineGoLiveDiff
