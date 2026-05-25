import Darwin
import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorKit
import Network

public struct MobilePairingNetworkInterface: Equatable, Sendable {
  public var name: String
  public var ipv4Address: String
  public var isUp: Bool
  public var isLoopback: Bool
  public var isPointToPoint: Bool
  public var supportsBroadcast: Bool

  public init(
    name: String,
    ipv4Address: String,
    isUp: Bool,
    isLoopback: Bool,
    isPointToPoint: Bool,
    supportsBroadcast: Bool
  ) {
    self.name = name
    self.ipv4Address = ipv4Address
    self.isUp = isUp
    self.isLoopback = isLoopback
    self.isPointToPoint = isPointToPoint
    self.supportsBroadcast = supportsBroadcast
  }
}

public final class MobileMacRelayRuntime: @unchecked Sendable {
  public let stationIdentity: MobilePairingStationIdentity
  public let storageRoot: URL

  private let pairingServer: MobilePairingHTTPServer
  private let trustedDeviceStore: MobileMacTrustedCommandDeviceStore
  private let relayService: MobileMacRelayService
  private let pollInterval: Duration
  private let now: @Sendable () -> Date
  private let lock = NSLock()
  private var pollTask: Task<Void, Never>?
  private var invitation: MobilePairingInvitation?

  public init(
    storageRoot: URL,
    stationName: String,
    clientProvider: @escaping @Sendable () async -> (any HarnessMonitorClientProtocol)?,
    clientFailureHandler: @escaping @Sendable (String) async -> Void = { _ in },
    pairingHost: String? = nil,
    pairingEndpoint: URL? = nil,
    pollInterval: Duration = .seconds(15),
    now: @escaping @Sendable () -> Date = Date.init
  ) throws {
    self.storageRoot = storageRoot
    self.pollInterval = pollInterval
    self.now = now
    let identityStore = MobileMacStationIdentityStore(
      fileURL: storageRoot.appendingPathComponent("station-identity.json")
    )
    let stationIdentity = try identityStore.loadOrCreate(stationName: stationName, now: now())
    self.stationIdentity = stationIdentity
    let trustedDeviceStore = try MobileMacTrustedCommandDeviceStore(
      fileURL: storageRoot.appendingPathComponent("trusted-mobile-devices.json")
    )
    self.trustedDeviceStore = trustedDeviceStore

    let database = LiveMobileCloudMirrorDatabase()
    let commandQueue = MobileCloudMirrorCommandQueue(
      database: database,
      trustedDeviceStore: trustedDeviceStore
    )
    let relayCommandQueue = MobileCloudMirrorRelayCommandQueue(
      commandQueue: commandQueue,
      receiptKeyID: stationIdentity.commandKeyID,
      now: now
    )
    let reviewsQueryStore = MobileRelayReviewsQueryPreferenceStore()
    let snapshotSource = HarnessMonitorClientMobileMirrorSnapshotSource(
      stationID: stationIdentity.stationID,
      stationName: stationIdentity.stationName,
      clientProvider: {
        guard let client = await clientProvider() else {
          return nil
        }
        return HarnessMonitorClientMobileMirrorClient(client: client)
      },
      reviewsQueryProvider: {
        reviewsQueryStore.queryRequest()
      },
      trustedDeviceProvider: {
        try await trustedDeviceStore.trustedDevices().map {
          MobileDeviceDescriptor(
            id: $0.deviceID,
            displayName: $0.displayName,
            publicKeyFingerprint: $0.signingKeyFingerprint,
            pairedAt: $0.pairedAt,
            lastCommandAt: $0.lastCommandAt
          )
        }
      },
      clientFailureHandler: clientFailureHandler
    )
    let snapshotSink = MobileCloudMirrorRelaySnapshotSink(
      stationID: stationIdentity.stationID,
      writer: MobileCloudMirrorSnapshotWriter(database: database),
      trustedDeviceStore: trustedDeviceStore,
      now: now
    )
    let commandClient = HarnessMonitorClientProviderMobileRelayCommandClient(
      clientProvider: clientProvider,
      reviewsQueryProvider: {
        reviewsQueryStore.queryRequest(forceRefresh: true)
      }
    )
    let relayService = MobileMacRelayService(
      stationID: stationIdentity.stationID,
      snapshotSource: snapshotSource,
      snapshotSink: snapshotSink,
      commandQueue: relayCommandQueue,
      executor: HarnessMonitorClientMobileRelayCommandExecutor(
        client: commandClient,
        now: now
      )
    )
    self.relayService = relayService
    pairingServer = MobilePairingHTTPServer(
      stationIdentity: stationIdentity,
      trustStore: trustedDeviceStore,
      host: pairingHost ?? Self.defaultPairingHost(),
      publicEndpoint: pairingEndpoint,
      now: now,
      onPairAccepted: {
        do {
          _ = try await relayService.publishSnapshot(now: now())
        } catch MobileCloudMirrorCloudKitError.schemaUnavailable {
          HarnessMonitorLogger.store.warning(
            "Mobile relay could not publish initial mirror because the CloudKit schema is unavailable."
          )
        } catch {
          HarnessMonitorLogger.store.warning(
            "Mobile relay initial mirror publish failed: \(String(describing: error), privacy: .public)"
          )
        }
      }
    )
  }

  deinit {
    stop()
  }

  public func start() {
    lock.lock()
    guard pollTask == nil else {
      lock.unlock()
      return
    }
    let task = Task.detached(priority: .utility) {
      [pairingServer, relayService, pollInterval, now]
      in
      do {
        let invitation = try await pairingServer.start()
        self.setInvitation(invitation)
      } catch {
        HarnessMonitorLogger.store.warning(
          "Mobile relay pairing server failed: \(String(describing: error), privacy: .public)"
        )
      }

      while !Task.isCancelled {
        do {
          _ = try await relayService.executePendingCommands(now: now())
        } catch let error as MobileMirrorSnapshotUnavailable {
          HarnessMonitorLogger.store.info(
            "Mobile relay waiting for initial Monitor mirror: \(String(describing: error), privacy: .public)"
          )
        } catch {
          HarnessMonitorLogger.store.warning(
            "Mobile relay tick failed: \(String(describing: error), privacy: .public)"
          )
        }

        do {
          try await Task.sleep(for: pollInterval)
        } catch {
          return
        }
      }
    }
    pollTask = task
    lock.unlock()
  }

  public func stop() {
    lock.lock()
    let task = pollTask
    pollTask = nil
    invitation = nil
    lock.unlock()
    task?.cancel()
    pairingServer.stop()
  }

  public func currentInvitation() -> MobilePairingInvitation? {
    lock.lock()
    defer { lock.unlock() }
    return invitation
  }

  public func currentInvitationURL() throws -> URL? {
    guard let invitation = currentInvitation() else {
      return nil
    }
    return try MobilePairingInvitationCodec.encode(invitation)
  }

  public func setPairingEndpoint(_ endpoint: URL?) {
    pairingServer.setPublicEndpoint(endpoint)
  }

  public func renewPairingInvitationURL() async throws -> URL {
    let invitation = try await pairingServer.renewInvitation()
    setInvitation(invitation)
    return try MobilePairingInvitationCodec.encode(invitation)
  }

  public func trustedDeviceDescriptors() async throws -> [MobileDeviceDescriptor] {
    try await trustedDeviceStore.trustedDevices().map {
      MobileDeviceDescriptor(
        id: $0.deviceID,
        displayName: $0.displayName,
        publicKeyFingerprint: $0.signingKeyFingerprint,
        pairedAt: $0.pairedAt,
        lastCommandAt: $0.lastCommandAt
      )
    }
  }

  private func setInvitation(_ invitation: MobilePairingInvitation) {
    lock.lock()
    self.invitation = invitation
    lock.unlock()
    do {
      let url = try MobilePairingInvitationCodec.encode(invitation)
      HarnessMonitorLogger.store.info(
        "Mobile relay pairing invitation ready: \(url.absoluteString, privacy: .private)"
      )
    } catch {
      HarnessMonitorLogger.store.warning(
        "Mobile relay could not encode invitation: \(String(describing: error), privacy: .public)"
      )
    }
  }

  public static func defaultPairingHost() -> String {
    preferredPairingHost(
      from: ipv4Interfaces(),
      fallbackHostName: ProcessInfo.processInfo.hostName
    )
  }

  public static func preferredPairingHost(
    from interfaces: [MobilePairingNetworkInterface],
    fallbackHostName: String
  ) -> String {
    selectedPairingInterface(from: interfaces)?.ipv4Address ?? fallbackHostName
  }

  private static func ipv4Interfaces() -> [MobilePairingNetworkInterface] {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
      return []
    }
    defer { freeifaddrs(interfaces) }

    var result: [MobilePairingNetworkInterface] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = firstInterface
    while let current = cursor {
      defer { cursor = current.pointee.ifa_next }
      let flags = Int32(current.pointee.ifa_flags)
      guard
        let address = current.pointee.ifa_addr,
        address.pointee.sa_family == UInt8(AF_INET)
      else {
        continue
      }

      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let nameInfoResult = getnameinfo(
        address,
        socklen_t(address.pointee.sa_len),
        &hostname,
        socklen_t(hostname.count),
        nil,
        0,
        NI_NUMERICHOST
      )
      guard nameInfoResult == 0 else {
        continue
      }
      let terminator = hostname.firstIndex(of: 0) ?? hostname.count
      let bytes = hostname[..<terminator].map { UInt8(bitPattern: $0) }
      let value = String(decoding: bytes, as: UTF8.self)
      if !value.isEmpty {
        let name = String(cString: current.pointee.ifa_name)
        result.append(
          MobilePairingNetworkInterface(
            name: name,
            ipv4Address: value,
            isUp: flags & IFF_UP != 0,
            isLoopback: flags & IFF_LOOPBACK != 0,
            isPointToPoint: flags & IFF_POINTOPOINT != 0,
            supportsBroadcast: flags & IFF_BROADCAST != 0
          )
        )
      }
    }
    return result
  }

  private static func selectedPairingInterface(
    from interfaces: [MobilePairingNetworkInterface]
  ) -> MobilePairingNetworkInterface? {
    interfaces.enumerated()
      .filter { _, interface in
        isUsablePairingInterface(interface)
      }
      .max { lhs, rhs in
        let lhsScore = pairingInterfaceScore(lhs.element)
        let rhsScore = pairingInterfaceScore(rhs.element)
        if lhsScore == rhsScore {
          return lhs.offset > rhs.offset
        }
        return lhsScore < rhsScore
      }?
      .element
  }

  private static func isUsablePairingInterface(
    _ interface: MobilePairingNetworkInterface
  ) -> Bool {
    interface.isUp
      && !interface.isLoopback
      && !interface.isPointToPoint
      && !interface.ipv4Address.isEmpty
      && !isUnusableIPv4Address(interface.ipv4Address)
  }

  private static func pairingInterfaceScore(_ interface: MobilePairingNetworkInterface) -> Int {
    var score = 0
    if interface.name == "en0" {
      score += 1_000
    } else if interface.name.hasPrefix("en") {
      score += 900
    } else if interface.name.hasPrefix("anpi") {
      score += 500
    } else if interface.name.hasPrefix("bridge") {
      score += 100
    }
    if interface.supportsBroadcast {
      score += 100
    }
    if isPrivateIPv4Address(interface.ipv4Address) {
      score += 50
    }
    return score
  }

  private static func isUnusableIPv4Address(_ address: String) -> Bool {
    address == "0.0.0.0"
      || address.hasPrefix("127.")
      || address.hasPrefix("169.254.")
  }

  private static func isPrivateIPv4Address(_ address: String) -> Bool {
    let components = address.split(separator: ".").compactMap { Int($0) }
    guard components.count == 4 else {
      return false
    }
    if components[0] == 10 {
      return true
    }
    if components[0] == 192, components[1] == 168 {
      return true
    }
    return components[0] == 172 && (16...31).contains(components[1])
  }
}
