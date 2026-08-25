import SwiftUI

#if canImport(UIKit) && canImport(VisionKit)
import UIKit
import VisionKit

/// Camera-based QR reader for Vamp Assistant's private pairing link.
/// The scanner only returns the payload; endpoint validation and pairing stay in
/// BeetCodePairingView so a random QR code can never trigger a connection.
struct BeetCodeQRScannerView: UIViewControllerRepresentable {
    let onPayload: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPayload: onPayload)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        guard DataScannerViewController.isSupported,
              DataScannerViewController.isAvailable else {
            return QRScannerUnavailableViewController()
        }

        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        scanner.view.backgroundColor = .black
        scanner.startScanningIfPossible()
        return scanner
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onPayload: (String) -> Void
        private var didReadPayload = false

        init(onPayload: @escaping (String) -> Void) {
            self.onPayload = onPayload
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]) {
            guard !didReadPayload else { return }
            for item in addedItems {
                guard case let .barcode(barcode) = item,
                      let payload = barcode.payloadStringValue,
                      !payload.isEmpty else { continue }
                didReadPayload = true
                dataScanner.stopScanning()
                onPayload(payload)
                return
            }
        }
    }
}

private final class QRScannerUnavailableViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let label = UILabel()
        label.text = "Camera scanning is unavailable on this device. Enter the address and six-digit code manually."
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .body)

        view.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
}

private extension DataScannerViewController {
    func startScanningIfPossible() {
        do {
            try startScanning()
        } catch {
            // The unavailable controller is still a safe manual-entry fallback.
        }
    }
}
#else

struct BeetCodeQRScannerView: View {
    let onPayload: (String) -> Void

    var body: some View {
        ContentUnavailableView(
            "QR scanning unavailable",
            systemImage: "qrcode.viewfinder",
            description: Text("Enter the Vamp Assistant address and six-digit code manually."))
    }
}
#endif
