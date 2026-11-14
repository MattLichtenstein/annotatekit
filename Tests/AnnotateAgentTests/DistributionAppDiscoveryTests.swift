// Verifies project-scoped distribution discovery without assuming that container access is allowed.

import Testing
@testable import AnnotateAgent

#if os(macOS)
@Suite struct DistributionAppDiscoveryTests {
    @Test func includesInstalledProjectAppsWithoutDeveloperOrContainerAccessFlags() {
        let apps: [[String: Any]] = [
            ["bundleIdentifier": "com.example.koa", "builtByDeveloper": false, "containerAccessible": false],
            ["bundleIdentifier": "com.example.shiba"],
            ["bundleIdentifier": "com.example.unrelated", "builtByDeveloper": false, "containerAccessible": true],
            ["bundleIdentifier": "com.example.debug", "builtByDeveloper": true],
            ["builtByDeveloper": true]
        ]
        #expect(DeviceCtlBridge.annotationAppIDs(in: apps, including: ["com.example.koa", "com.example.shiba"])
                == ["com.example.koa", "com.example.shiba", "com.example.debug"])
    }

    @Test func existingDeveloperDiscoveryRemainsRestrictedWithoutProjectIDs() {
        let apps: [[String: Any]] = [
            ["bundleIdentifier": "com.example.release", "builtByDeveloper": false],
            ["bundleIdentifier": "com.example.debug", "builtByDeveloper": true]
        ]
        #expect(DeviceCtlBridge.annotationAppIDs(in: apps, including: []) == ["com.example.debug"])
    }
}
#endif
