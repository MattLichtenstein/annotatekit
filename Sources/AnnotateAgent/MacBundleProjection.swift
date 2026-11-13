import AnnotateCore
import Foundation

/// Builds attachment-safe subsets while preserving unknown manifest fields and the source batch.
enum MacBundleProjection {
    static func write(source: URL, destination: URL, keeping ids: Set<UUID>, sessionID: String? = nil) throws {
        let manager = FileManager.default
        let manifest = source.appendingPathComponent("session.json")
        guard var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any] else { throw MacInboxStore.Failure.invalidBundle }
        let session = try AnnotationSession.decoder.decode(AnnotationSession.self, from: Data(contentsOf: manifest))
        let kept = session.annotations.filter { ids.contains($0.id) }
        let keptScreens = Set(kept.map(\.screen))
        let changedScreens = Set(session.annotations.filter { !ids.contains($0.id) }.map(\.screen))
        raw["annotations"] = (raw["annotations"] as? [[String: Any]] ?? []).filter { item in
            (item["id"] as? String).flatMap(UUID.init(uuidString:)).map(ids.contains) == true
        }
        raw["screens"] = (raw["screens"] as? [[String: Any]] ?? []).compactMap { item -> [String: Any]? in
            guard let index = item["index"] as? Int, keptScreens.contains(index) else { return nil }
            var screen = item
            // Original annotated frames contain ignored markers/sketches. Kept crops retain their
            // own markup; clean frames provide screen context without exposing ignored markup.
            if changedScreens.contains(index) { screen.removeValue(forKey: "annotatedImage") }
            return screen
        }
        if let sessionID { raw["id"] = sessionID }
        let projectedData = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys, .prettyPrinted])
        let projected = try AnnotationSession.decoder.decode(AnnotationSession.self, from: projectedData)
        let references = Set(projected.screens.flatMap { [$0.image, $0.annotatedImage, $0.hiResImage].compactMap { $0 } }
            + kept.flatMap { [$0.crop].compactMap { $0 } + ($0.attachments ?? []) })
        try manager.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for path in references {
            guard SessionInbox.isSafeRelativePath(path) else { throw MacInboxStore.Failure.invalidBundle }
            let from = source.appendingPathComponent(path)
            guard from.resolvingSymlinksInPath().path.hasPrefix(source.resolvingSymlinksInPath().path + "/"),
                  (try from.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).isRegularFile == true,
                  (try from.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw MacInboxStore.Failure.invalidBundle }
            let to = destination.appendingPathComponent(path)
            try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(contentsOf: from).write(to: to, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: to.path)
        }
        let original = try String(contentsOf: source.appendingPathComponent("prompt.md"), encoding: .utf8)
        let lines = original.components(separatedBy: "\n")
        let completion = lines.lastIndex(where: { $0.hasPrefix("Full detail (all frames, visible text per screen, sketch vectors): ") })
            .map { lines.dropFirst($0 + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
        let prompt = PromptRenderer.render(projected, sessionPath: destination.path, completion: completion)
        try Data(prompt.utf8).write(to: destination.appendingPathComponent("prompt.md"), options: .atomic)
        try projectedData.write(to: destination.appendingPathComponent("session.json"), options: .atomic)
        try synchronize(directory: destination)
    }

    static func synchronize(directory: URL) throws {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let files = manager.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else { throw MacInboxStore.Failure.invalidBundle }
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw MacInboxStore.Failure.invalidBundle }
            try manager.setAttributes([.posixPermissions: values.isDirectory == true ? 0o700 : 0o600], ofItemAtPath: file.path)
            if values.isRegularFile == true {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.synchronize()
            }
        }
    }
}
