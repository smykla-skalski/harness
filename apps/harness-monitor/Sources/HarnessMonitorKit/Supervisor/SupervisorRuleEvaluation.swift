struct SupervisorRuleEvaluation: Sendable {
  let ruleID: String
  let rule: any PolicyRule
  let actions: [SupervisorAction]
  let failed: Bool
}
