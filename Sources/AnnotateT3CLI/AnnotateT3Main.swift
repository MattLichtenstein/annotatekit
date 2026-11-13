import AnnotateAgent
import AnnotateCore
import Foundation
import Dispatch
#if os(macOS)
import Darwin
#endif

/// Starts the Mac inbox window app, its menu bar extra, or the standalone T3 connector.
@main
struct AnnotateT3Main {
    @MainActor
    static func main() {
        #if os(macOS)
        let command = CommandLine.arguments.dropFirst().first
        let surface: InboxSurface? = switch Bundle.main.bundleIdentifier {
        case InboxSurface.windowBundleID: .window
        case InboxSurface.menuBarBundleID: .menuBar
        default: command == "app" ? .window : command == "menu" ? .menuBar : nil
        }
        if let surface {
            do {
                let arguments = Array(CommandLine.arguments.dropFirst())
                func option(_ name: String) -> String? {
                    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
                    return arguments[index + 1]
                }
                let configuration: ReceiverService.Configuration
                if let root = option("--root"), let projectID = option("--project") {
                    configuration = ReceiverService.Configuration(root: root, projectID: projectID, node: option("--node") ?? "/opt/homebrew/bin/node",
                        credentials: option("--credentials") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AnnotateKit/t3-credentials.json").path)
                } else {
                    guard let file = Bundle.main.url(forResource: "receiver-config", withExtension: "json") else {
                        throw failure("Install the app with tools/install-mac-inbox.sh, or supply app|menu --root and --project.")
                    }
                    configuration = try JSONDecoder().decode(ReceiverService.Configuration.self, from: Data(contentsOf: file))
                }
                InboxLaunch.run(surface, configuration: configuration)
            } catch {
                FileHandle.standardError.write(Data("annotate-t3: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }
        #endif
        // AppKit owns a synchronous main run loop in menu mode. CLI commands drain asynchronous
        // work through Dispatch, without holding a main-actor job around NSApp.run.
        Task {
            do { try await run(); exit(0) }
            catch {
                FileHandle.standardError.write(Data("annotate-t3: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
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
            annotate-t3 app|menu --project <project ID> --root <source checkout> [--credentials <path>] [--node <path>]
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
        let process = HelperProcess()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                // The adapter emits bounded errors, never credentials or server response bodies.
                try process.run(executable: node, arguments: [script] + arguments, capturesOutput: capturesOutput)
            }.value
        } onCancel: { process.cancel() }
    }
}
