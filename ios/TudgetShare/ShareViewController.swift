import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// Entry point for "Screenshot a bank alert → Share → Tudget".
///
/// The extension writes straight into the shared SwiftData store rather than
/// queueing something for the app to pick up later, so a purchase captured
/// this way is in the ledger — and on the widgets — before the share sheet has
/// finished dismissing.
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        loadImage()
    }

    private func loadImage() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = item.attachments?.first(where: {
                  $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
              })
        else {
            present(image: nil)
            return
        }

        provider.loadItem(forTypeIdentifier: UTType.image.identifier) { [weak self] value, _ in
            let image: UIImage? = {
                switch value {
                case let image as UIImage: return image
                case let url as URL: return (try? Data(contentsOf: url)).flatMap(UIImage.init(data:))
                case let data as Data: return UIImage(data: data)
                default: return nil
                }
            }()

            DispatchQueue.main.async { self?.present(image: image) }
        }
    }

    private func present(image: UIImage?) {
        let review = ShareReviewView(
            image: image,
            onFinish: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.cancel() }
        )

        let host = UIHostingController(rootView: review)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(
            withError: NSError(domain: "com.adamodeven.tudget.share", code: 0)
        )
    }
}
