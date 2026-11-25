import SwiftUI
import Photos
import UniformTypeIdentifiers

struct ReceivedView: View {
    let delivery: Delivery
    @Environment(\.dismiss) private var dismiss
    @State private var photosNote: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                    VStack(spacing: 4) {
                        Text("From \(delivery.from)").font(.title2.bold())
                        if delivery.felt {
                            Text("Felt on your table").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    content
                    if let photosNote {
                        Text(photosNote).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var content: some View {
        switch delivery.content {
        case .text(let text):
            Text("Copied to your clipboard").foregroundStyle(.secondary)
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
               let scheme = url.scheme, ["http", "https"].contains(scheme) {
                Link(destination: url) { Label("Open Link", systemImage: "safari") }
                    .buttonStyle(.borderedProminent)
            }
            ShareLink(item: text).buttonStyle(.bordered)

        case .image(let url):
            if let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            Text("Copied to your clipboard").foregroundStyle(.secondary)
            HStack {
                saveButton([url])
                ShareLink(item: url).buttonStyle(.bordered)
            }

        case .files(let files):
            VStack(spacing: 0) {
                ForEach(files, id: \.url) { f in
                    HStack(spacing: 12) {
                        Image(systemName: Self.icon(f.url)).foregroundStyle(.tint).frame(width: 26)
                        Text(f.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Files.human(f.size)).font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10).padding(.horizontal, 14)
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            let urls = files.map(\.url)
            HStack {
                if urls.allSatisfy(Self.isMedia) { saveButton(urls) }
                ShareLink(items: urls) { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
            }
            Text("Saved in Files › On My iPhone › KnockDrop").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func saveButton(_ urls: [URL]) -> some View {
        Button {
            Task { photosNote = await Self.saveToPhotos(urls) }
        } label: {
            Label("Save to Photos", systemImage: "photo.badge.plus")
        }
        .buttonStyle(.borderedProminent)
    }

    static func isMedia(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
        return t.conforms(to: .image) || t.conforms(to: .movie)
    }

    static func icon(_ url: URL) -> String {
        guard let t = UTType(filenameExtension: url.pathExtension) else { return "doc" }
        if t.conforms(to: .image) { return "photo" }
        if t.conforms(to: .movie) { return "film" }
        if t.conforms(to: .pdf) { return "doc.richtext" }
        if t.conforms(to: .text) { return "doc.text" }
        if t.conforms(to: .archive) { return "doc.zipper" }
        return "doc"
    }

    static func saveToPhotos(_ urls: [URL]) async -> String {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return "KnockDrop isn't allowed to add to Photos (Settings › KnockDrop › Photos)"
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for u in urls {
                    let isVideo = UTType(filenameExtension: u.pathExtension)?.conforms(to: .movie) == true
                    PHAssetCreationRequest.forAsset().addResource(with: isVideo ? .video : .photo, fileURL: u, options: nil)
                }
            }
            return urls.count == 1 ? "Saved to Photos" : "Saved \(urls.count) to Photos"
        } catch {
            return "Couldn't save to Photos: \(error.localizedDescription)"
        }
    }
}
