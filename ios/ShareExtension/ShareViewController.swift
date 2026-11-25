import UIKit
import SwiftUI

/// "KnockDrop" in any app's share sheet: tap a rhythm, and the share stays open while this sheet is up.
final class ShareViewController: UIViewController {
    private let sharing = Sharing()
    private let input = KnockInput()

    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        sharing.from = UIDevice.current.name
        input.onPattern = { [weak self] p, _ in self?.sharing.use(p) }
        sharing.prepare { try await Staging.shared(providers) }

        let host = UIHostingController(rootView: ShareExtensionView(sharing: sharing, input: input) { [weak self] in
            self?.finish()
        })
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        input.setActive(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        input.setActive(false)
        sharing.stop()
    }

    private func finish() {
        input.setActive(false)
        sharing.stop()
        extensionContext?.completeRequest(returningItems: nil)
    }
}

struct ShareExtensionView: View {
    let sharing: Sharing
    let input: KnockInput
    let done: () -> Void
    @State private var note: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                TapPad { input.tap($0) }.ignoresSafeArea()
                if sharing.phase == .none {
                    VStack(spacing: 14) {
                        Text(note ?? "Nothing to share")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Close", action: done).buttonStyle(.bordered)
                    }
                    .padding()
                } else {
                    SharingPanel(sharing: sharing, input: input, onDone: done)
                }
                VStack {
                    Spacer()
                    if sharing.phase == .live {
                        Text("Keep this open until they have it")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let note, sharing.phase != .none {
                        Text(note).font(.callout).padding(10)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
                .padding()
                .allowsHitTesting(false)
            }
            .navigationTitle("KnockDrop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sharing.phase == .live ? "Done" : "Cancel", action: done)
                }
            }
        }
        .onChange(of: sharing.note) { _, n in
            if let n { note = n; sharing.clearNote() }
        }
        .onChange(of: sharing.phase) { _, _ in input.reset() }
    }
}
