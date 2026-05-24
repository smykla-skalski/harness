import Darwin
import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorKit
import Network

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
    pairingHost: String? = nil,
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
    pairingServer = MobilePairingHTTPServer(
      stationIdentity: stationIdentity,
      trustStore: trustedDeviceStore,
      host: pairingHost ?? Self.defaultPairingHost(),
      now: now
    )

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
    let snapshotSource = HarnessMonitorClientMobileMirrorSnapshotSource(
      stationID: stationIdentity.stationID,
      stationName: stationIdentity.stationName,
      clientProvider: {
        guard let client = await clientProvider() else {
          return nil
        }
        return HarnessMonitorClientMobileMirrorClient(client: client)
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
      }
    )
    let snapshotSink = MobileCloudMirrorRelaySnapshotSink(
      stationID: stationIdentity.stationID,
      writer: MobileCloudMirrorSnapshotWriter(database: database),
      trustedDeviceStore: trustedDeviceStore,
      now: now
    )
    let commandClient = HarnessMonitorClientProviderMobileRelayCommandClient(
      clientProvider: clientProvider
    )
    relayService = MobileMacRelayService(
      stationID: stationIdentity.stationID,
      snapshotSource: snapshotSource,
      snapshotSink: snapshotSink,
      commandQueue: relayCommandQueue,
      executor: HarnessMonitorClientMobileRelayCommandExecutor(
        client: commandClient,
        now: now
      )
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
    if let host = firstNonLoopbackIPv4Address() {
      return host
    }
    return ProcessInfo.processInfo.hostName
  }

  private static func firstNonLoopbackIPv4Address() -> String? {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
      return nil
    }
    defer { freeifaddrs(interfaces) }

    var cursor: UnsafeMutablePointer<ifaddrs>? = firstInterface
    while let current = cursor {
      defer { cursor = current.pointee.ifa_next }
      let flags = Int32(current.pointee.ifa_flags)
      guard
        flags & IFF_UP != 0,
        flags & IFF_LOOPBACK == 0,
        let address = current.pointee.ifa_addr,
        address.pointee.sa_family == UInt8(AF_INET)
      else {
        continue
      }

      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let result = getnameinfo(
        address,
        socklen_t(address.pointee.sa_len),
        &hostname,
        socklen_t(hostname.count),
        nil,
        0,
        NI_NUMERICHOST
      )
      guard result == 0 else {
        continue
      }
      let terminator = hostname.firstIndex(of: 0) ?? hostname.count
      let bytes = hostname[..<terminator].map { UInt8(bitPattern: $0) }
      let value = String(decoding: bytes, as: UTF8.self)
      if !value.isEmpty {
        return value
      }
    }
    return nil
  }
}
