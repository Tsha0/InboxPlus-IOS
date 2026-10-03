import InboxPlusBridge
import SwiftUI
import CoreImage
#if os(iOS)
import UIKit
#endif

/// Shown when a bridge offers more than one way in, such as Facebook's sign-in domains.
struct LoginFlowPickerView: View {
    let flows: [BridgeLoginFlow]
    let onSelect: (BridgeLoginFlow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose how to sign in")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(flows, id: \.id) { flow in
                Button { onSelect(flow) } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(flow.name).fontWeight(.semibold)
                            if !flow.description.isEmpty {
                                Text(flow.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("login-flow-\(flow.id)")
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}

/// Renders a QR payload without pulling in a dependency; CoreImage ships the generator.
enum QRCodeRenderer {
    /// Renders a payload at a whole number of points per module, near the requested size.
    ///
    /// WhatsApp's payload is long enough to need a 67-module code, and a phone camera reads that
    /// off a screen only if the modules are square and evenly sized. Sizing to an arbitrary frame
    /// resamples the grid — some modules a pixel wider than their neighbours — so the size follows
    /// the module count rather than the other way round.
    static func image(for payload: String, approximateSize: CGFloat = 300) -> PlatformImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let modules = max(output.extent.width, 1)
        let scale = max(1, (approximateSize / modules).rounded())
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: scaled.extent.width, height: scaled.extent.height)
        )
        #endif
    }
}
