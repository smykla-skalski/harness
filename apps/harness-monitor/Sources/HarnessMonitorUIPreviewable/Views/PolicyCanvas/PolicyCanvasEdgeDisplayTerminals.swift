import SwiftUI

func policyCanvasPreferredSourceSide(
  request: PolicyCanvasDisplayedEdgeRouteRequest,
  sourceTerminal: PolicyCanvasPortTerminal?,
  fixedSourceSide: PolicyCanvasPortSide?,
  sourceFrame: CGRect?,
  targetFrame: CGRect?
) -> PolicyCanvasPortSide {
  policyCanvasPreferredSourceSide(
    input: PolicyCanvasPreferredSourceSideInput(
      fixedSide: fixedSourceSide,
      forcedFanOutSide: request.familyPreference.forcedSourceSide,
      terminalSide: sourceTerminal?.side,
      natural: policyCanvasResolvedPortSide(for: request.edge.source),
      isFanInMember: request.familyPreference.forcedTargetSide == .top,
      sourceFrame: sourceFrame,
      targetFrame: targetFrame
    )
  )
}

func policyCanvasEffectiveSourceTerminal(
  _ terminal: PolicyCanvasPortTerminal?,
  preferredSide: PolicyCanvasPortSide
) -> PolicyCanvasPortTerminal? {
  guard let terminal, terminal.side == preferredSide else {
    return nil
  }
  return terminal
}

func policyCanvasEffectiveTargetTerminal(
  _ terminal: PolicyCanvasPortTerminal?,
  fixedTargetSide: PolicyCanvasPortSide?
) -> PolicyCanvasPortTerminal? {
  guard let terminal else {
    return nil
  }
  guard fixedTargetSide == nil || fixedTargetSide == terminal.side else {
    return nil
  }
  return terminal
}
