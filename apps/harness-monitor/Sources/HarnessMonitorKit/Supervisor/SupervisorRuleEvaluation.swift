struct SupervisorRuleEvaluation: Sendable {
  let ruleID: String
  let rule: any PolicyRule
  let actions: [PolicyAction]
  let failed: Bool
}
