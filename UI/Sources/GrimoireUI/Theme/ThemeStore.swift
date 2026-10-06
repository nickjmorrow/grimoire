import Foundation
import Observation

@Observable
public final class ThemeStore {
    public private(set) var current: Theme
    public private(set) var available: [Theme]

    @ObservationIgnored private let folder: URL?
    @ObservationIgnored private let followSystemAppearance: Bool
    @ObservationIgnored private var pinnedName: String?
    @ObservationIgnored private var systemAppearance: Theme.Appearance = .dark
    @ObservationIgnored private var fileStamps: [String: Date] = [:]
    @ObservationIgnored private var timer: Timer?

    public init(folder: URL?, followSystemAppearance: Bool = true) {
        self.folder = folder
        self.followSystemAppearance = followSystemAppearance
        self.available = [.midnightSun, .midnightSunLight]
        self.current = .midnightSun
        reload()
    }

    deinit { timer?.invalidate() }

    public func select(name: String) {
        guard available.contains(where: { $0.name == name }) else { return }
        pinnedName = name
        resolveCurrent()
    }

    public func setSystemAppearance(_ appearance: Theme.Appearance) {
        guard followSystemAppearance else { return }
        systemAppearance = appearance
        resolveCurrent()
    }

    public func reload() {
        let stamps = Self.stamps(in: folder)
        fileStamps = stamps
        var themes: [Theme] = [.midnightSun, .midnightSunLight]
        for url in Self.jsonFiles(in: folder) {
            guard let data = try? Data(contentsOf: url),
                  let theme = try? JSONDecoder().decode(Theme.self, from: data) else { continue }
            if let index = themes.firstIndex(where: { $0.name == theme.name }) {
                themes[index] = theme
            } else {
                themes.append(theme)
            }
        }
        available = themes
        resolveCurrent()
    }

    public func startWatching(interval: TimeInterval = 1.0) {
        stopWatching()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, Self.stamps(in: self.folder) != self.fileStamps else { return }
            self.reload()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    private func resolveCurrent() {
        if let pinnedName, let theme = available.first(where: { $0.name == pinnedName }) {
            current = theme
            return
        }
        let preferred = systemAppearance == .dark ? "Midnight Sun" : "Midnight Sun Light"
        let matches = available.filter { $0.appearance == systemAppearance }
        current = matches.first(where: { $0.name == preferred }) ?? matches.first ?? current
    }

    private static func jsonFiles(in folder: URL?) -> [URL] {
        guard let folder,
              let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func stamps(in folder: URL?) -> [String: Date] {
        var result: [String: Date] = [:]
        for url in jsonFiles(in: folder) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            result[url.lastPathComponent] = values?.contentModificationDate ?? .distantPast
        }
        return result
    }
}
