import Foundation

@main
struct ImporterTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let repo = root.appendingPathComponent("destination")
        for profile in ["stock", "community-rgb"] {
            let defaults = repo.appendingPathComponent("config/\(profile)")
            try fm.createDirectory(at: defaults, withIntermediateDirectories: true)
            try "default manifest \(profile)".write(to: defaults.appendingPathComponent("west.yml"), atomically: true, encoding: .utf8)
            try "default settings \(profile)".write(to: defaults.appendingPathComponent("glove80.conf"), atomically: true, encoding: .utf8)
        }
        let keymap = root.appendingPathComponent("my-layout.keymap")
        try "user keymap".write(to: keymap, atomically: true, encoding: .utf8)
        let importer = ZMKConfigImporter()
        let single = try importer.importConfiguration(from: keymap, into: repo, profile: .communityRGB)
        let singleContents = try String(contentsOf: single.configDirectory.appendingPathComponent("glove80.keymap"), encoding: .utf8)
        assert(singleContents == "user keymap")
        assert(fm.fileExists(atPath: keymap.path))
        let defaultManifest = try String(contentsOf: single.configDirectory.appendingPathComponent("west.yml"), encoding: .utf8)
        assert(defaultManifest == "default manifest community-rgb")

        let source = root.appendingPathComponent("source/config")
        try fm.createDirectory(at: source.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "original".write(to: source.appendingPathComponent("glove80.keymap"), atomically: true, encoding: .utf8)
        try "user manifest".write(to: source.appendingPathComponent("west.yml"), atomically: true, encoding: .utf8)
        try "user settings".write(to: source.appendingPathComponent("glove80.conf"), atomically: true, encoding: .utf8)
        try "source".write(to: source.appendingPathComponent("src/module.c"), atomically: true, encoding: .utf8)
        // Empty excluded fixtures contain no credentials.
        for name in [".env", "credentials.yml", "identity.pem"] {
            fm.createFile(atPath: source.appendingPathComponent(name).path, contents: Data())
        }
        try fm.createDirectory(at: source.appendingPathComponent("secrets"), withIntermediateDirectories: true)
        fm.createFile(atPath: source.appendingPathComponent("secrets/settings.yml").path, contents: Data())
        try fm.createSymbolicLink(at: source.appendingPathComponent("linked.keymap"), withDestinationURL: keymap)
        let folder = try importer.importConfiguration(from: source.deletingLastPathComponent(), into: repo, profile: .stock)
        for (name, expected) in [("glove80.keymap", "original"), ("west.yml", "user manifest"), ("glove80.conf", "user settings"), ("src/module.c", "source")] {
            let contents = try String(contentsOf: folder.configDirectory.appendingPathComponent(name), encoding: .utf8)
            assert(contents == expected)
        }
        for name in [".env", "credentials.yml", "identity.pem", "linked.keymap", "secrets"] {
            assert(!fm.fileExists(atPath: folder.configDirectory.appendingPathComponent(name).path))
        }
        assert(folder.directory != single.directory)
        let empty = root.appendingPathComponent("empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        let before = try fm.contentsOfDirectory(atPath: repo.appendingPathComponent("user-config").path)
        do {
            _ = try importer.importConfiguration(from: empty, into: repo, profile: .stock)
            fatalError("Expected missing keymap error")
        } catch ZMKConfigImporter.ImportError.missingKeymap {}
        let after = try fm.contentsOfDirectory(atPath: repo.appendingPathComponent("user-config").path)
        assert(after.sorted() == before.sorted())
        let linked = root.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: linked, withDestinationURL: source)
        do {
            _ = try importer.importConfiguration(from: linked, into: repo, profile: .stock)
            fatalError("Expected symlink rejection")
        } catch ZMKConfigImporter.ImportError.symbolicLink {}
        print("Import tests passed: preservation, defaults, source files, exclusions, isolation, failure cleanup, and symlink rejection")
    }
}
