/// Which detail section the Decisions detail column renders. Lifted to the
/// window root so the principal-toolbar segmented picker and the detail body
/// share one source of truth.
public enum DecisionDetailTab: String, CaseIterable, Identifiable {
  case context
  case audit

  public var id: Self { self }

  public var title: String {
    switch self {
    case .context:
      "Context"
    case .audit:
      "Audit Trail"
    }
  }
}
