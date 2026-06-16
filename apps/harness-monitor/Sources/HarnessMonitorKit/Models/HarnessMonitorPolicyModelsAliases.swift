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
