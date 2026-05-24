import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import HarnessMonitorCore
import HarnessMonitorKit
import HarnessMonitorMacRelay
import SwiftUI

struct MobileRelayPairingSettingsPanel: View {
  let runtime: MobileMacRelayRuntime
  @State private var invitationURL: URL?
  @State private var qrCodeImage: NSImage?
  @State private var qrCodeImageValue: String?
  @State private var trustedDevices: [MobileDeviceDescriptor] = []
  @State private var status = "Pairing relay is starting."
  @State private var isRefreshing = false
  @State private var pairingEndpointDraft = MobileRelayPairingEndpointDefaults.defaultValue
  @AppStorage(MobileRelayPairingEndpointDefaults.storageKey)
  private var pairingEndpointSetting = MobileRelayPairingEndpointDefaults.defaultValue

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 14) {
        qrCode
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline) {
            Label("Pair iPhone or Apple Watch", systemImage: "qrcode.viewfinder")
              .font(.headline)
            Spacer(minLength: 12)
            Button {
              Task { await renewInvitation() }
            } label: {
              Label("New Code", systemImage: "arrow.clockwise")
            }
            .disabled(isRefreshing)
            if let invitationURL {
              Button {
                copy(invitationURL)
              } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
              }
            }
          }

          Text(status)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

          if let invitationURL {
            Text(invitationURL.absoluteString)
              .font(.system(.caption, design: .monospaced))
              .lineLimit(2)
              .textSelection(.enabled)
              .foregroundStyle(.secondary)
          }

          endpointOverrideEditor
          trustedDeviceStrip
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(.separator.opacity(0.45), lineWidth: 1)
    }
    .padding(.horizontal, 20)
    .padding(.bottom, 14)
    .task {
      pairingEndpointDraft = pairingEndpointSetting
      applyStoredEndpointToRuntime()
      await refreshState()
    }
  }

  private var endpointOverrideEditor: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Public endpoint")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        TextField("Use local network endpoint", text: $pairingEndpointDraft)
          .textFieldStyle(.roundedBorder)
          .font(.system(.caption, design: .monospaced))
        Button("Apply") {
          Task { await applyPairingEndpointSetting() }
        }
        .disabled(isRefreshing)
        Button("Clear") {
          pairingEndpointDraft = ""
          Task { await applyPairingEndpointSetting() }
        }
        .disabled(isRefreshing || pairingEndpointDraft.isEmpty)
      }
    }
  }

  @ViewBuilder private var qrCode: some View {
    if let invitationURL,
      let image = qrCodeImage,
      qrCodeImageValue == invitationURL.absoluteString
    {
      Image(nsImage: image)
        .interpolation(.none)
        .resizable()
        .frame(width: 96, height: 96)
        .accessibilityLabel("Harness pairing QR code")
    } else {
      ZStack {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(.quaternary)
        ProgressView()
          .controlSize(.small)
      }
      .frame(width: 96, height: 96)
      .accessibilityLabel("Pairing QR code loading")
    }
  }

  @ViewBuilder private var trustedDeviceStrip: some View {
    if trustedDevices.isEmpty {
      Label("No trusted mobile devices yet", systemImage: "iphone.slash")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(trustedDevices) { device in
            Label(device.displayName, systemImage: "iphone")
              .font(.caption)
              .padding(.horizontal, 8)
              .padding(.vertical, 5)
              .background {
                Capsule()
                  .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
              }
              .overlay {
                Capsule()
                  .stroke(.separator.opacity(0.35), lineWidth: 1)
              }
              .help(device.publicKeyFingerprint)
          }
        }
      }
      .frame(height: 30)
    }
  }

  @MainActor
  private func refreshState() async {
    do {
      if let currentURL = try runtime.currentInvitationURL() {
        updateInvitationURL(currentURL)
        status = "Scan this code in Harness Monitor on iPhone. The link uses harness://pair."
      } else {
        updateInvitationURL(nil)
        status = "Pairing server is starting. Create a new code in a moment."
      }
      trustedDevices = try await runtime.trustedDeviceDescriptors()
    } catch {
      status = "Pairing status unavailable: \(String(describing: error))"
    }
  }

  @MainActor
  private func renewInvitation() async {
    isRefreshing = true
    defer { isRefreshing = false }
    do {
      updateInvitationURL(try await runtime.renewPairingInvitationURL())
      trustedDevices = try await runtime.trustedDeviceDescriptors()
      status = "New one-time pairing code is ready. The link uses harness://pair."
    } catch {
      status = "Could not create a pairing code yet: \(String(describing: error))"
    }
  }

  @MainActor
  private func applyPairingEndpointSetting() async {
    let trimmed = pairingEndpointDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      pairingEndpointSetting = ""
      runtime.setPairingEndpoint(nil)
      await renewInvitation()
      return
    }
    guard let endpoint = MobileRelayPairingEndpointDefaults.endpoint(from: trimmed) else {
      status = "Public endpoint must be an absolute http:// or https:// URL."
      return
    }
    pairingEndpointDraft = endpoint.absoluteString
    pairingEndpointSetting = endpoint.absoluteString
    runtime.setPairingEndpoint(endpoint)
    await renewInvitation()
  }

  private func applyStoredEndpointToRuntime() {
    runtime.setPairingEndpoint(MobileRelayPairingEndpointDefaults.endpoint(from: pairingEndpointSetting))
  }

  private func copy(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
  }

  @MainActor
  private func updateInvitationURL(_ url: URL?) {
    invitationURL = url
    let value = url?.absoluteString
    guard qrCodeImageValue != value else {
      return
    }
    qrCodeImageValue = value
    qrCodeImage = value.flatMap(MobileRelayQRCodeRenderer.image(from:))
  }
}

private enum MobileRelayQRCodeRenderer {
  static func image(from value: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(value.utf8)
    filter.correctionLevel = "M"
    guard let outputImage = filter.outputImage else {
      return nil
    }
    let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    guard let cgImage = CIContext().createCGImage(transformed, from: transformed.extent) else {
      return nil
    }
    return NSImage(cgImage: cgImage, size: NSSize(width: 96, height: 96))
  }
}
