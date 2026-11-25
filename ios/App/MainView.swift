import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct MainView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var showSettings = false

    private var sharing: Sharing { model.sharing }
    private var input: KnockInput { model.input }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if model.networkTrouble { networkWarning }
                NearbyList(offers: model.nearby, receivingFrom: model.receivingFrom)
                pad
                shareBar
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .navigationTitle("KnockDrop")
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
        .sheet(item: $model.delivery) { ReceivedView(delivery: $0) }
        .sheet(isPresented: $showSettings) { SettingsView(model: model) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            sharing.prepare { try await Staging.imported(urls) }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            sharing.prepare { try await Staging.photos(items) }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { model.setActive(true) }
            if phase == .background { model.setActive(false) }
        }
        .onChange(of: sharing.phase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = phase == .live   // a locked phone can't share
            input.reset()
        }
        .onChange(of: sharing.note) { _, note in
            if let note { model.say(note); sharing.clearNote() }
        }
    }

    // MARK: the pad

    private var pad: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(.secondarySystemBackground))
            TapPad { input.tap($0) }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            if sharing.isBusy {
                SharingPanel(sharing: sharing, input: input)
            } else {
                receivePrompt.allowsHitTesting(false)
            }
            VStack {
                Spacer()
                if let note = model.note {
                    Text(note)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .allowsHitTesting(false)
            .animation(.spring(duration: 0.3), value: model.note)
        }
        .frame(maxHeight: .infinity)
    }

    private var receivePrompt: some View {
        VStack(spacing: 14) {
            if let who = model.receivingFrom {
                ProgressView().controlSize(.large)
                Text("Receiving from \(who)…").font(.headline)
            } else {
                Image(systemName: "hand.tap")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tint)
                VStack(spacing: 6) {
                    Text(model.nearby.isEmpty ? "Nobody nearby is sharing yet" : "Tap their rhythm anywhere here")
                        .font(.title3.bold())
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                LiveRhythm(input: input).padding(.horizontal, 36)
                if input.feelKnocks && input.motionAvailable {
                    Label("Feeling for knocks", systemImage: "waveform.path")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .symbolEffect(.bounce, value: input.feltCount)
                }
            }
        }
        .padding()
    }

    private var subtitle: String {
        let feel = input.feelKnocks && input.motionAvailable
        if model.nearby.isEmpty {
            return feel ? "Leave your phone on the table. When someone knocks on it to share, it lands here."
                        : "When someone on this Wi-Fi shares, they show up above."
        }
        return feel ? "or knock it on the table" : "Same rhythm, any speed"
    }

    // MARK: sharing

    private var shareBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Share").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                PasteButton(supportedContentTypes: [.image, .plainText, .url]) { providers in
                    Task { @MainActor in sharing.prepare { try await Staging.clipboard(providers) } }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                PhotosPicker(selection: $photoItems, maxSelectionCount: 20, matching: .any(of: [.images, .videos])) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                Button { importing = true } label: { Label("Files", systemImage: "folder") }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(sharing.isBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var networkWarning: some View {
        Button {
            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
        } label: {
            Label("KnockDrop can't see your Wi-Fi. Allow Local Network access in Settings.",
                  systemImage: "wifi.exclamationmark")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
    }
}

/// Who's sharing nearby.
struct NearbyList: View {
    let offers: [NearbyOffer]
    let receivingFrom: String?

    var body: some View {
        if !offers.isEmpty {
            VStack(spacing: 0) {
                ForEach(offers) { o in
                    HStack(spacing: 12) {
                        Image(systemName: icon(o))
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(o.from).font(.body.weight(.semibold)).lineLimit(1)
                            Text(o.size > 0 && o.clipboard == nil ? "\(o.label), \(Files.human(o.size))" : o.label)
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if receivingFrom == o.from { ProgressView() } else { KnockDots(count: o.knocks) }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .accessibilityElement(children: .combine)
                    if o.id != offers.last?.id { Divider().padding(.leading, 56) }
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .transition(.opacity)
        }
    }

    private func icon(_ o: NearbyOffer) -> String {
        switch o.clipboard {
        case "text": return "doc.on.clipboard"
        case "image": return "photo"
        default: return o.fileCount == 1 ? "doc" : "doc.on.doc"
        }
    }
}
