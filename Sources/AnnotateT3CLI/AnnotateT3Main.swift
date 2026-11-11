import AnnotateAgent
import AnnotateCore
import Foundation
#if os(macOS)
import Darwin
#endif

/// Runs the opt-in Mac-only T3 connector with an inbox separate from legacy annotation consumers.
@main
struct AnnotateT3Main {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("annotate-t3: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        #if os(macOS)
        var arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "help"
        if !arguments.isEmpty { arguments.removeFirst() }
        func option(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard command == "login" || command == "serve" else {
            print("""
            annotate-t3 login --origin <T3 origin> [--credentials <Mac-only path>] [--node <node path>]
            annotate-t3 serve --project <project ID> --root <source checkout> [--credentials <path>] [--node <path>]
            Approve the login at a permission ceiling that permits your destination threads.
            Credentials stay in Application Support; only a bounded catalog and receipts reach the phone.
            """)
            return
        }
        let credentials = option("--credentials") ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AnnotateKit/t3-credentials.json").path
        let node = option("--node") ?? "/opt/homebrew/bin/node"
        let script = Bundle.module.resourceURL!.appendingPathComponent("Resources/t3-bridge.mjs").path
        if command == "login" {
            guard let origin = option("--origin") else { throw failure("Specify --origin for your running T3 environment") }
            guard try await helper(node, script, ["login", credentials, origin], capturesOutput: false) else {
                throw failure("T3 sign-in did not finish")
            }
            return
        }
        guard let project = option("--project"), let rootPath = option("--root") else {
            throw failure("Specify --project and --root")
        }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        let output = root.appendingPathComponent(".annotate/t3", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: output.path)
        // OS-owned lock recovers immediately after a crash and excludes concurrent routing consumers.
        let lock = open(output.appendingPathComponent("receiver.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw failure("Cannot create receiver lock") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw failure("A T3 receiver already owns this inbox") }
        let mirror = DeviceCtlBridge.makeIfAvailable().map {
            DeviceMirror(outputDirectory: output, cutoffID: "", bridge: $0, projectRoot: root,
                         remoteDirectory: "Documents/.annotate/t3", sharedFiles: [T3ThreadCatalog.fileName])
        }
        let runtime = AgentRuntime(outputDirectory: output, mirror: mirror) {
            AgentPresence(agent: "T3", mode: .push, via: "t3")
        }
        let runtimeTask = Task { await runtime.run() }
        defer { runtimeTask.cancel() }
        while !Task.isCancelled {
            let succeeded = (try? await helper(node, script, ["tick", credentials, output.path, project], capturesOutput: true)) == true
            if !succeeded {
                // Replace availability without retaining stale titles after a permission/sign-in failure.
                let catalog = T3ThreadCatalog(projectID: project, isAvailable: false, threads: [])
                try? AnnotationSession.encoder.encode(catalog).write(to: output.appendingPathComponent(T3ThreadCatalog.fileName), options: .atomic)
            }
            try await Task.sleep(for: .seconds(5))
        }
        #else
        throw failure("The developer-device T3 connector requires macOS")
        #endif
    }

    static func failure(_ message: String) -> NSError { NSError(domain: "AnnotateT3", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

    static func helper(_ node: String, _ script: String, _ arguments: [String], capturesOutput: Bool) async throws -> Bool {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [script] + arguments
            if capturesOutput { process.standardOutput = FileHandle.nullDevice }
            // The helper emits bounded errors, never the credential or server response body.
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }
}
