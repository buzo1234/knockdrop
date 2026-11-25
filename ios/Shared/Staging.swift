#if canImport(UIKit)
import UIKit
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// What's about to be shared, copied into a private folder so it can't change or vanish
/// while someone is downloading it.
struct Draft {
    let files: [URL]
    let clipboard: String?   // "text" | "image": it goes on the receiver's clipboard
    let label: String
}

enum StagingError: LocalizedError {
    case empty(String)
    var errorDescription: String? {
        switch self { case .empty(let s): return s }
    }
}

enum Staging {
    static let prefix = "knockdrop-share"

    /// Leftovers from earlier shares (the system clears tmp too, eventually).
    static func cleanUp() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix(prefix) {
            try? fm.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    // MARK: clipboard (the Paste button)

    /// Clipboard text or image, sent the way the Mac menu bar app sends a clipboard:
    /// it lands on the receiver's clipboard, not in their Downloads.
    static func clipboard(_ providers: [NSItemProvider]) async throws -> Draft {
        let folder = Files.scratchFolder(prefix)
        for p in providers {
            if p.canLoadObject(ofClass: UIImage.self), let img = try? await p.loadObject(UIImage.self),
               let png = img.pngData() {
                let url = folder.appendingPathComponent("Clipboard image.png")
                try png.write(to: url)
                return Draft(files: [url], clipboard: "image", label: "your clipboard image")
            }
            if let text = try? await text(from: p), !text.isEmpty {
                let url = folder.appendingPathComponent("Clipboard text.txt")
                try text.write(to: url, atomically: true, encoding: .utf8)
                return Draft(files: [url], clipboard: "text", label: "your clipboard text")
            }
        }
        throw StagingError.empty("There's nothing to share on your clipboard")
    }

    // MARK: anything (share sheet)

    /// Items from another app's share sheet. One piece of text or one link goes to the
    /// receiver's clipboard; anything else is sent as files.
    static func shared(_ providers: [NSItemProvider]) async throws -> Draft {
        let folder = Files.scratchFolder(prefix)
        if !providers.contains(where: isFile), providers.count == 1, let text = try? await text(from: providers[0]), !text.isEmpty {
            let url = folder.appendingPathComponent("Shared text.txt")
            try text.write(to: url, atomically: true, encoding: .utf8)
            return Draft(files: [url], clipboard: "text", label: providers[0].hasItemConformingToTypeIdentifier(UTType.url.identifier) ? "a link" : "text")
        }
        var urls: [URL] = []
        for (i, p) in providers.enumerated() {
            if let u = try? await file(from: p, into: folder) {
                urls.append(u)
            } else if let text = try? await text(from: p), !text.isEmpty {
                let u = Files.uniqueURL(in: folder, name: "Shared text \(i + 1).txt")
                try text.write(to: u, atomically: true, encoding: .utf8)
                urls.append(u)
            }
        }
        guard !urls.isEmpty else { throw StagingError.empty("KnockDrop can't share this") }
        return Draft(files: urls, clipboard: nil, label: describe(urls))
    }

    // MARK: Photos and Files

    static func photos(_ items: [PhotosPickerItem]) async throws -> Draft {
        let folder = Files.scratchFolder(prefix)
        var urls: [URL] = []
        for (i, item) in items.enumerated() {
            if let picked = try? await item.loadTransferable(type: PickedFile.self) {
                let dest = Files.uniqueURL(in: folder, name: picked.url.lastPathComponent)
                try FileManager.default.moveItem(at: picked.url, to: dest)
                urls.append(dest)
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let dest = Files.uniqueURL(in: folder, name: "Photo \(i + 1).\(ext)")
                try data.write(to: dest)
                urls.append(dest)
            }
        }
        guard !urls.isEmpty else { throw StagingError.empty("Couldn't load those photos") }
        return Draft(files: urls, clipboard: nil, label: describe(urls))
    }

    /// Files picked in the Files app: security-scoped, so copy them while we may.
    static func imported(_ picked: [URL]) async throws -> Draft {
        let folder = Files.scratchFolder(prefix)
        var urls: [URL] = []
        for u in picked {
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let dest = Files.uniqueURL(in: folder, name: u.lastPathComponent)
            try FileManager.default.copyItem(at: u, to: dest)
            urls.append(dest)
        }
        guard !urls.isEmpty else { throw StagingError.empty("Folders can't be shared yet; pick files") }
        return Draft(files: urls, clipboard: nil, label: describe(urls))
    }

    // MARK: helpers

    static func describe(_ urls: [URL]) -> String {
        let types = urls.compactMap { UTType(filenameExtension: $0.pathExtension) }
        let size = Files.human(urls.reduce(0) { $0 + Files.size(of: $1) })
        let n = urls.count
        if types.count == n, types.allSatisfy({ $0.conforms(to: .image) }) {
            return n == 1 ? "a photo, \(size)" : "\(n) photos, \(size)"
        }
        if types.count == n, types.allSatisfy({ $0.conforms(to: .image) || $0.conforms(to: .movie) }) {
            return n == 1 ? "a video, \(size)" : "\(n) photos and videos, \(size)"
        }
        return n == 1 ? "\(urls[0].lastPathComponent), \(size)" : "\(n) files, \(size)"
    }

    private static func text(from p: NSItemProvider) async throws -> String? {
        if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = try? await p.loadObject(NSURL.self) as URL? {
            return url.absoluteString
        }
        if p.canLoadObject(ofClass: NSString.self), let s = try await p.loadObject(NSString.self) {
            return s as String
        }
        return nil
    }

    /// A real file type: data that isn't just text or a link.
    private static func fileType(_ p: NSItemProvider) -> UTType? {
        p.registeredTypeIdentifiers.compactMap(UTType.init)
            .first { $0.conforms(to: .data) && !$0.conforms(to: .plainText) && !$0.conforms(to: .url) }
    }

    private static func isFile(_ p: NSItemProvider) -> Bool {
        fileType(p) != nil || p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }

    /// The provider's file, copied into `folder` under its own name.
    private static func file(from p: NSItemProvider, into folder: URL) async throws -> URL? {
        guard let type = fileType(p) else {
            // some apps hand over only a file URL
            guard p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                  let u = try await p.loadObject(NSURL.self) as URL?, u.isFileURL else { return nil }
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            let dest = Files.uniqueURL(in: folder, name: u.lastPathComponent)
            try FileManager.default.copyItem(at: u, to: dest)
            return dest
        }
        let suggested = p.suggestedName
        return try await withCheckedThrowingContinuation { cont in
            _ = p.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else { cont.resume(throwing: error ?? StagingError.empty("No file")); return }
                var name = suggested ?? url.deletingPathExtension().lastPathComponent
                let ext = type.preferredFilenameExtension ?? url.pathExtension
                if (name as NSString).pathExtension.isEmpty, !ext.isEmpty { name += "." + ext }
                let dest = Files.uniqueURL(in: folder, name: name)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)   // `url` is deleted when we return
                    cont.resume(returning: dest)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

/// A photo or video from PhotosPicker as the original file, not re-encoded data.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let dest = Files.uniqueURL(in: Files.scratchFolder(Staging.prefix), name: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedFile(url: dest)
        }
    }
}

extension NSItemProvider {
    func loadObject<T: NSItemProviderReading>(_ type: T.Type) async throws -> T? {
        try await withCheckedThrowingContinuation { cont in
            _ = loadObject(ofClass: type) { obj, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: obj as? T) }
            }
        }
    }
}
#endif
