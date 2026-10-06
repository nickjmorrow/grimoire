import Foundation
import Testing
@testable import GrimoireUI

@Suite struct ThemeTests {
    // MARK: helpers
    static func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("themes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ theme: Theme, to folder: URL, file: String = "t.json") throws {
        try JSONEncoder().encode(theme).write(to: folder.appendingPathComponent(file))
    }

    static func luminance(_ hex: String) -> Double {
        guard let c = HexColor.rgba(hex) else { return 0 }
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    static func contrast(_ a: String, _ b: String) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    // MARK: decoding and hex
    @Test func decodesThemeJSON() throws {
        let json = """
        {"name":"X","appearance":"light","colors":{"background":"#fff","surface":"#fff","surfaceRaised":"#fff","text":"#000","textDim":"#000","textFaint":"#000","accent":"#000","link":"#000","tag":"#000","bullet":"#000","selection":"#00000040","code":"#000","codeBackground":"#fff","border":"#ccc","success":"#0a0","warning":"#fa0","danger":"#f00"},
        "fonts":{"bodySize":16,"titleSize":30,"codeSize":14,"lineHeightMultiple":1.4,"family":"Helvetica"},
        "spacing":{"indent":20,"blockGap":4,"pagePadding":24},"radius":6}
        """
        let theme = try JSONDecoder().decode(Theme.self, from: Data(json.utf8))
        #expect(theme.name == "X")
        #expect(theme.appearance == .light)
        #expect(theme.fonts.family == "Helvetica")
        #expect(theme.fonts.codeFamily == nil)
        #expect(theme.radius == 6)
    }

    @Test func parsesHex() throws {
        let short = try #require(HexColor.rgba("#f80"))
        #expect(short.r == 1 && abs(short.g - 136.0 / 255) < 1e-9 && short.b == 0 && short.a == 1)
        let long = try #require(HexColor.rgba("#0b1120"))
        #expect(abs(long.r - 11.0 / 255) < 1e-9 && long.a == 1)
        let alpha = try #require(HexColor.rgba("#ffcc3380"))
        #expect(abs(alpha.a - 128.0 / 255) < 1e-9)
        for bad in ["", "#", "#12", "#12345", "#1234567", "#ggg", "red", "#ffcc33zz"] {
            #expect(HexColor.rgba(bad) == nil, "\(bad)")
        }
    }

    @Test func platformColorAndFontsBuild() {
        let theme = Theme.midnightSun
        _ = theme.colors.platformColor(\.accent)
        _ = theme.colors.swiftUI(\.accent)
        #expect(theme.bodyFont().pointSize == 15)
        #expect(theme.titleFont().pointSize == 28)
        #expect(theme.codeFont().pointSize == 13.5)
    }

    // MARK: bundled themes
    @Test func bundledThemesLoadWithDistinctAppearances() {
        #expect(Theme.midnightSun.name == "Midnight Sun")
        #expect(Theme.midnightSunLight.name == "Midnight Sun Light")
        #expect(Theme.midnightSun.appearance == .dark)
        #expect(Theme.midnightSunLight.appearance == .light)
        #expect(Theme.midnightSun.spacing.indent == 22)
        #expect(Theme.midnightSun.fonts.lineHeightMultiple == 1.35)
    }

    @Test func bundledColorsAreAllValidHex() {
        for theme in [Theme.midnightSun, .midnightSunLight] {
            for (label, value) in Mirror(reflecting: theme.colors).children {
                #expect(HexColor.rgba(value as? String ?? "") != nil, "\(theme.name) \(label ?? "?")")
            }
        }
    }

    @Test func bundledThemesMeetWCAGContrast() {
        for theme in [Theme.midnightSun, .midnightSunLight] {
            let c = theme.colors
            for bg in [c.background, c.surface] {
                for fg in [c.text, c.textDim, c.link, c.tag, c.accent] {
                    #expect(Self.contrast(fg, bg) >= 4.5, "\(theme.name) \(fg) on \(bg) = \(Self.contrast(fg, bg))")
                }
            }
        }
    }

    // MARK: store
    @Test func folderThemeOverridesBundledByName() throws {
        let folder = try Self.tempFolder()
        var custom = Theme.midnightSun
        custom.radius = 99
        try Self.write(custom, to: folder)
        let store = ThemeStore(folder: folder)
        #expect(store.available.count == 2)
        #expect(store.current.radius == 99)
    }

    @Test func folderAddsNewTheme() throws {
        let folder = try Self.tempFolder()
        var custom = Theme.midnightSun
        custom.name = "Extra"
        try Self.write(custom, to: folder)
        #expect(ThemeStore(folder: folder).available.map(\.name).contains("Extra"))
    }

    @Test func invalidJSONIsIgnored() throws {
        let folder = try Self.tempFolder()
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("bad.json"))
        let store = ThemeStore(folder: folder)
        #expect(store.available.count == 2)
        #expect(store.current == .midnightSun)
    }

    @Test func missingFolderIsFine() {
        let store = ThemeStore(folder: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"))
        #expect(store.available.count == 2)
        #expect(ThemeStore(folder: nil).current == .midnightSun)
    }

    @Test func selectPinsAndIgnoresUnknownNames() {
        let store = ThemeStore(folder: nil)
        store.select(name: "Midnight Sun Light")
        #expect(store.current.name == "Midnight Sun Light")
        store.select(name: "Nope")
        #expect(store.current.name == "Midnight Sun Light")
        store.setSystemAppearance(.dark)
        #expect(store.current.name == "Midnight Sun Light")
    }

    @Test func systemAppearanceSwitchesWhenUnpinned() {
        let store = ThemeStore(folder: nil)
        store.setSystemAppearance(.light)
        #expect(store.current.name == "Midnight Sun Light")
        store.setSystemAppearance(.dark)
        #expect(store.current.name == "Midnight Sun")
    }

    @Test func systemAppearanceIgnoredWhenNotFollowing() {
        let store = ThemeStore(folder: nil, followSystemAppearance: false)
        store.setSystemAppearance(.light)
        #expect(store.current.name == "Midnight Sun")
    }

    @Test func reloadPicksUpChangedFile() throws {
        let folder = try Self.tempFolder()
        var custom = Theme.midnightSun
        custom.radius = 1
        try Self.write(custom, to: folder)
        let store = ThemeStore(folder: folder)
        #expect(store.current.radius == 1)
        custom.radius = 2
        try Self.write(custom, to: folder)
        store.reload()
        #expect(store.current.radius == 2)
    }

    @Test @MainActor func watchingReloadsOnChange() async throws {
        let folder = try Self.tempFolder()
        var custom = Theme.midnightSun
        custom.radius = 1
        try Self.write(custom, to: folder)
        let store = ThemeStore(folder: folder)
        store.startWatching(interval: 0.1)
        defer { store.stopWatching() }
        try await Task.sleep(nanoseconds: 200_000_000)
        custom.radius = 3
        try Self.write(custom, to: folder)
        // Make sure the mtime differs even on coarse-resolution filesystems.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: folder.appendingPathComponent("t.json").path)
        for _ in 0..<30 where store.current.radius != 3 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(store.current.radius == 3)
    }
}
