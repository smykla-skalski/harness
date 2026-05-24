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
  @State private var trustedDevices: [MobileDeviceDescriptor] = []
  @State private var status = "Pairing relay is starting."
  @State private var isRefreshing = false

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

          trustedDeviceStrip
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(.separator.opacity(0.45), lineWidth: 1)
    }
    .padding(.horizontal, 20)
    .padding(.bottom, 14)
    .task {
      await refreshState()
    }
  }

  @ViewBuilder private var qrCode: some View {
    if let invitationURL,
      let image = MobileRelayQRCodeRenderer.image(from: invitationURL.absoluteString)
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
              .background(.thinMaterial, in: Capsule())
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
        invitationURL = currentURL
        status = "Scan this code in Harness Monitor on iPhone. The link uses harness://pair."
      } else {
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
      invitationURL = try await runtime.renewPairingInvitationURL()
      trustedDevices = try await runtime.trustedDeviceDescriptors()
      status = "New one-time pairing code is ready. The link uses harness://pair."
    } catch {
      status = "Could not create a pairing code yet: \(String(describing: error))"
    }
  }

  private func copy(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
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
