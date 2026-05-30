import Testing

@testable import HarnessMonitorUIPreviewable

/// `OpenDashboardRouteAction` is injected into the dashboard window environment
/// from a computed property, so a fresh value is built on every host body pass.
/// Without a stable identity SwiftUI treats each re-injection as a change and
/// re-evaluates every `@Environment(\.openDashboardRoute)` reader (the Debugging
/// route) on every column toggle. These tests pin the opt-in identity equality
/// that lets re-injection of the same logical action compare equal.
@Suite("Open dashboard route action identity equality")
struct OpenDashboardRouteActionEquatableTests {
  private final class IdentityTarget {}

  @Test("actions sharing the same object identity compare equal")
  func sameObjectIdentityEqual() {
    let target = IdentityTarget()
    let lhs = OpenDashboardRouteAction(identity: ObjectIdentifier(target)) { _ in }
    let rhs = OpenDashboardRouteAction(identity: ObjectIdentifier(target)) { _ in }
    #expect(lhs == rhs)
  }

  @Test("actions with different object identities stay distinct")
  func differentIdentityNotEqual() {
    // Hold both targets alive so their identifiers are taken from coexisting
    // objects (otherwise ARC could reuse the address and collide them).
    let targetA = IdentityTarget()
    let targetB = IdentityTarget()
    let lhs = OpenDashboardRouteAction(identity: ObjectIdentifier(targetA)) { _ in }
    let rhs = OpenDashboardRouteAction(identity: ObjectIdentifier(targetB)) { _ in }
    #expect(lhs != rhs)
  }

  @Test("identity-less actions stay distinct, preserving prior always-changed behavior")
  func nilIdentityNotEqual() {
    let lhs = OpenDashboardRouteAction()
    let rhs = OpenDashboardRouteAction()
    #expect(lhs != rhs)
  }

  @Test("an identity-less action never matches an identified one")
  func nilVersusIdentifiedNotEqual() {
    let target = IdentityTarget()
    let identified = OpenDashboardRouteAction(identity: ObjectIdentifier(target)) { _ in }
    #expect(OpenDashboardRouteAction() != identified)
  }
}
