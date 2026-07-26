import Foundation

public struct SyncConfig: Sendable {
    public var baseURL: URL
    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public static let production = SyncConfig(
        baseURL: URL(string: "https://medication-tracker.jamiewhite.site/api/v1")!
    )
}
