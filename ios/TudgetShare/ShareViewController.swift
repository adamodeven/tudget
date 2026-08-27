import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// The share extension: log a purchase without opening the app.
///
/// iOS doesn't let one app read another app's notifications, so the closest
/// thing to the Android notification-listener plan is this -- screenshot the
/// bank alert (or long-press the banner and share it), hit Tudget in the share
/// sheet, and the purchase is captured in a couple of taps.
///
/// The extension never touches the app's SwiftData store. It writes a
/// `PendingPurchase` into the App Group inbox, which the app drains the next
/// time it's opened. That keeps two processes off one database and means a
/// capture survives the app never being launched.
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        let root = ShareReviewView(
            loadAttachment: { [weak self] in await self?.loadAttachment() ?? .empty },
            onComplete: { [weak self] in self?.complete() },
            onCancel: { [weak self] in self?.cancel() }
        )

        let hosting = UIHostingController(rootView: root)
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    // MARK: - Input

    enum Attachment {
        case image(UIImage, Data)
        case text(String)
        case empty
    }

    /// Pulls whatever was shared out of the extension context. Images are the
    /// main case (a screenshot); shared text is supported too, since copying
    /// the notification text works just as well.
    private func loadAttachment() async -> Attachment {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let providers = item.attachments else { return .empty }

        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            if let attachment = await loadImage(from: provider) { return attachment }
        }

        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            if let text = await loadText(from: provider) { return .text(text) }
        }

        return .empty
    }

    private func loadImage(from provider: NSItemProvider) async -> Attachment? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier) { item, _ in
                // The item arrives as a file URL, raw Data, or an already
                // decoded UIImage depending on the source app.
                var data: Data?
                if let url = item as? URL {
                    data = try? Data(contentsOf: url)
                } else if let raw = item as? Data {
                    data = raw
                } else if let image = item as? UIImage {
                    data = image.jpegData(compressionQuality: 0.9)
                }

                guard let data, let image = UIImage(data: data) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: .image(image, data))
            }
        }
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.text.identifier) { item, _ in
                continuation.resume(returning: item as? String)
            }
        }
    }

    // MARK: - Output

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(
            withError: NSError(domain: "app.tudget.share", code: NSUserCancelledError)
        )
    }
}
