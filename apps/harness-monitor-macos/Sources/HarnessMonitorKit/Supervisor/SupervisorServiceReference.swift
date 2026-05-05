import Foundation

final class SupervisorServiceReference: @unchecked Sendable {
  weak var service: SupervisorService?

  init(_ service: SupervisorService) {
    self.service = service
  }
}
