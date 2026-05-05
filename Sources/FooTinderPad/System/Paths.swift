import Foundation

enum Paths {
    static let appName = "FooTinderPad"

    static var configURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent(appName, isDirectory: true).appendingPathComponent("config.json")
    }

    static var bundledDefaultConfigURL: URL? {
        Bundle.main.url(forResource: "DefaultConfig", withExtension: "json")
    }

    static func ensureConfigDirectoryExists() throws {
        let dir = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
