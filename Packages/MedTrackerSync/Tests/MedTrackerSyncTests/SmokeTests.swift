import Foundation
import Testing
@testable import MedTrackerSync

@Test func packageBuildsAndConfigResolves() {
    let cfg = SyncConfig(baseURL: URL(string: "https://example.test/api/v1")!)
    #expect(cfg.baseURL.absoluteString == "https://example.test/api/v1")
    #expect(SyncConfig.production.baseURL.path == "/api/v1")
}
