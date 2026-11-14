// Enables the private in-process accessibility bootstrap only in Debug. Release uses public
// element scanning, explicit registrations, drawings, and location pins without loading private APIs.

#if canImport(UIKit)
import Foundation
#if DEBUG
import Darwin
#endif

@MainActor
enum AccessibilityBootstrap {
    static var isSupported: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    #if DEBUG
    private static var didEnable = false
    #endif

    static func enable() {
        #if DEBUG
        guard !didEnable else { return }
        didEnable = true

        var paths = ["/usr/lib/libAccessibility.dylib"]
        if let simulatorRoot = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] {
            paths.insert(simulatorRoot + "/usr/lib/libAccessibility.dylib", at: 0)
        }

        typealias SetEnabled = @convention(c) (Int32) -> Void
        for path in paths {
            guard let handle = dlopen(path, RTLD_NOW),
                  let symbol = dlsym(handle, "_AXSSetAutomationEnabled") else { continue }
            unsafeBitCast(symbol, to: SetEnabled.self)(1)
            return
        }
        #endif
    }
}
#endif
