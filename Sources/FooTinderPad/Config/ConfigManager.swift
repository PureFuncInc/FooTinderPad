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
        // Placeholder so all stored properties are initialized before we call
        // an instance method. loadOnce() will replace it with the real config.
        self.current = .empty
        self.current = self.loadOnce().config
    }

    /// First-load chain: try the user file, then the bundled default, then the
    /// in-memory hard-coded default, then `.empty`. Used by `init` and `start`,
    /// not by hot-reload (hot-reload preserves the previous config on failure).
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
                return LoadResult(config: .empty, warnings: ["fallback to empty config"])
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
        log.info("config loaded from \(self.url.path, privacy: .public) (warnings=\(r.warnings.count))")
    }

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
        debounce?.cancel()
        debounce = nil
    }

    /// Manual reload (menu bar item). On parse / read failure, keeps the
    /// previous `current` and emits a warning rather than swapping in a default.
    func reloadNow() {
        swapFromUserFile()
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

    /// Reads the user file and tries to swap it in. Preserves the previous
    /// `current` on any failure (the spec contract for hot reload).
    private func swapFromUserFile() {
        do {
            let data = try Data(contentsOf: url)
            let r = try ConfigLoader.load(from: data)
            current = r.config
            onSwap?(r.config)
            onWarnings?(r.warnings)
            log.info("config reloaded (warnings=\(r.warnings.count))")
        } catch {
            log.warning("reload failed (\(error.localizedDescription, privacy: .public)); keeping previous config")
            onWarnings?(["reload failed: \(error.localizedDescription)"])
        }
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
        // Hot reload: keep previous `current` on parse / read failure.
        // Re-arm regardless because the file may have been renamed by an
        // atomic-write editor (closing our fd against the old inode).
        swapFromUserFile()
        armSource()
    }
}

