import Foundation

public enum NeedsMeCloudKitError: Error, Equatable {
    case notAuthenticated
    case networkUnavailable
    case quotaExceeded
    case underlying(String)
}
