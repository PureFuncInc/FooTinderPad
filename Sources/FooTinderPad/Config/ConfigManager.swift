import Foundation
import os

final class ConfigManager {
    private let log = Logger(subsystem: "com.purefuncinc.FooTinderPad", category: "ConfigManager")
    private let url: URL
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debounce: DispatchWorkItem?
    private(set) var current: ResolvedConfig

    /// Called on the main queue every time the config is successfully reloaded.
    var onSwap: ((ResolvedConfig) -> Void)?
    /// Called whenever `current` changes; visible warnings (e.g. for menu bar surface).
    var onWarnings: (([String]) -> Void)?

    init(configURLOverride: URL? = nil) {
        self.url = configURLOverride ?? Paths.configURL
        self.current = ConfigManager.loadInitial(url: self.url)
    }

    func loadOnce() -> LoadResult {
        do {
            let data = try Data(contentsOf: url)
            return try ConfigLoader.load(from: data)
        } catch {
            log.warning("loadOnce failed (\(error.localizedDescription, privacy: .public)); using bundled default")
            do {
                let data = try ConfigManager.readBundledOrEmbeddedDefault()
                return try ConfigLoader.load(from: data)
            } catch {
                log.error("default config also unparseable: \(error.localizedDescription, privacy: .public)")
                return LoadResult(config: ResolvedConfig.empty, warnings: ["fallback to empty config"])
            }
        }
    }

    func start() {
        ensureFileExists()
        let r = loadOnce()
        current = r.config
        onSwap?(r.config)
        onWarnings?(r.warnings)
        armSource()
    }

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
        debounce?.cancel()
        debounce = nil
    }

    func reloadNow() {
        let r = loadOnce()
        current = r.config
        onSwap?(r.config)
        onWarnings?(r.warnings)
    }

    // MARK: - private

    private func ensureFileExists() {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: url.path) else { return }
        do {
            let data = try ConfigManager.readBundledOrEmbeddedDefault()
            try data.write(to: url)
        } catch {
            log.error("could not seed default config: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func readBundledOrEmbeddedDefault() throws -> Data {
        if let bundled = Paths.bundledDefaultConfigURL {
            return try Data(contentsOf: bundled)
        }
        return DefaultConfig.data
    }

    private static func loadInitial(url: URL) -> ResolvedConfig {
        let mgr = ConfigManager(_internalURL: url)
        return mgr.loadOnce().config
    }

    private init(_internalURL url: URL) {
        self.url = url
        self.current = ResolvedConfig.empty
    }

    private func armSource() {
        source?.cancel()
        if fd >= 0 { close(fd); fd = -1 }

        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            log.error("open(O_EVTONLY) failed for \(self.url.path, privacy: .public)")
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        s.setEventHandler { [weak self] in self?.scheduleReload() }
        s.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        source = s
        s.resume()
    }

    private func scheduleReload() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performReload() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func performReload() {
        // The file may have been renamed by editors that write atomically.
        // Re-arm regardless of success so we keep watching the path.
        let r = loadOnce()
        current = r.config
        onSwap?(r.config)
        onWarnings?(r.warnings)
        armSource()
    }
}

