import Foundation
import Network
import CryptoKit

struct ReceivedFile: Equatable {
    let name: String
    let size: Int64
    var url: URL
    let clipboard: String?   // "text" | "image" | "files" when it came off the sender's clipboard
}

enum ClaimOutcome {
    case received(from: String, files: [ReceivedFile])
    case rejected(String)
}

/// Knock on an offer's door with our rhythm; on a match, download everything into `folder`.
/// The sender compares rhythms (we never learn theirs). Same protocol as try_claim() in knockdrop.py.
func claim(_ offer: NearbyOffer, pattern: [Double], me: String, into folder: URL) async throws -> ClaimOutcome {
    let conn = Conn(to: offer.endpoint)
    defer { conn.cancel() }
    try await conn.start()
    try await conn.sendJSON(["id": offer.id, "pattern": pattern, "from": me])
    let resp = try await conn.readJSON()
    guard resp["ok"] as? Bool == true else {
        return .rejected(resp["reason"] as? String ?? "rejected")
    }
    guard let items = resp["files"] as? [[String: Any]] else { throw KDError.badResponse }
    let from = (resp["from"] as? String) ?? offer.from

    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var saved: [ReceivedFile] = []
    do {
        for item in items {
            guard let name = item["name"] as? String, let size = (item["size"] as? NSNumber)?.int64Value,
                  size >= 0, let digest = item["sha256"] as? String else { throw KDError.badResponse }
            let dest = Files.uniqueURL(in: folder, name: name)
            let part = dest.appendingPathExtension("part")
            FileManager.default.createFile(atPath: part.path, contents: nil)
            let out = try FileHandle(forWritingTo: part)
            var hasher = SHA256()
            var left = size
            do {
                while left > 0 {
                    guard let chunk = try await conn.read(max: Int(min(Int64(KD.chunk), left))) else { throw KDError.closed }
                    try out.write(contentsOf: chunk)
                    hasher.update(data: chunk)
                    left -= Int64(chunk.count)
                }
                try out.close()
            } catch {
                try? out.close()
                try? FileManager.default.removeItem(at: part)
                throw error
            }
            guard hasher.finalize().hex == digest else {
                try? FileManager.default.removeItem(at: part)
                throw KDError.checksum(name)
            }
            try FileManager.default.moveItem(at: part, to: dest)
            let kind = (item["clipboard"] as? String).flatMap { KD.clipboardKinds.contains($0) ? $0 : nil }
            saved.append(ReceivedFile(name: Files.safeName(name), size: size, url: dest, clipboard: kind))
        }
    } catch {
        for f in saved { try? FileManager.default.removeItem(at: f.url) }   // all or nothing
        throw error
    }
    return .received(from: from, files: saved)
}
