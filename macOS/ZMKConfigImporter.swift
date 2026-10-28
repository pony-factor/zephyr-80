import Foundation

struct ZMKConfigImporter {
    enum Profile: String, CaseIterable {
        case stock
        case communityRGB = "community-rgb"
    }

    struct ImportedConfiguration {
        let directory: URL
        var configDirectory: URL { directory.appendingPathComponent("config", isDirectory: true) }
    }

    enum ImportError: LocalizedError {
        case invalidSelection, missingKeymap, symbolicLink, unsupportedKeymaps
        var errorDescription: String? {
            switch self {
            case .invalidSelection: return "Choose a .keymap file or a ZMK configuration folder."
            case .missingKeymap: return "The selected configuration needs a Glove80 keymap."
            case .symbolicLink: return "Import regular files and folders rather than symbolic links."
            case .unsupportedKeymaps: return "Use glove80.keymap, a matching glove80_lh.keymap and glove80_rh.keymap pair, or a single keymap file."
            }
        }
    }

    private let manager = FileManager.default
    private let ignoredDirectories: Set<String> = ["build", "node_modules", "zephyr", "zmk", "user-config"]
    private let sourceExtensions: Set<String> = ["keymap", "conf", "dtsi", "dts", "overlay", "c", "h", "yaml", "yml"]

    // Inspect filenames and file types, then copy only configuration source.
    // Hidden files, symlinks, firmware binaries, and credential files are excluded.
    private func excludedName(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix(".") || ["secret", "credential", "token", "password", "private", "certificate"].contains(where: name.contains)
    }

    private func allowed(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        guard !excludedName(url) else { return false }
        return sourceExtensions.contains(url.pathExtension.lowercased()) || name == "cmakelists.txt" || name == "kconfig" || name.hasPrefix("kconfig.")
    }

    func importConfiguration(from selected: URL, into repository: URL, profile: Profile) throws -> ImportedConfiguration {
        let properties: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let values = try selected.resourceValues(forKeys: properties)
        guard values.isSymbolicLink != true else { throw ImportError.symbolicLink }
        let isDirectory = values.isDirectory == true
        guard isDirectory || (values.isRegularFile == true && selected.pathExtension.lowercased() == "keymap" && allowed(selected)) else {
            throw ImportError.invalidSelection
        }
        var source = selected
        if isDirectory {
            let nested = selected.appendingPathComponent("config", isDirectory: true)
            if manager.fileExists(atPath: nested.path) {
                let nestedValues = try nested.resourceValues(forKeys: properties)
                guard nestedValues.isSymbolicLink != true else { throw ImportError.symbolicLink }
                if nestedValues.isDirectory == true { source = nested }
            }
        }

        let storage = repository.appendingPathComponent("user-config", isDirectory: true)
        if manager.fileExists(atPath: storage.path),
           try storage.resourceValues(forKeys: properties).isSymbolicLink == true { throw ImportError.symbolicLink }
        try manager.createDirectory(at: storage, withIntermediateDirectories: true)
        let destination = storage.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let config = destination.appendingPathComponent("config", isDirectory: true)
        try manager.createDirectory(at: config, withIntermediateDirectories: true)
        var completed = false
        defer { if !completed { try? manager.removeItem(at: destination) } }

        if !isDirectory {
            try manager.copyItem(at: source, to: config.appendingPathComponent("glove80.keymap"))
        } else {
            var enumerationError: Error?
            guard let enumerator = manager.enumerator(at: source, includingPropertiesForKeys: Array(properties), options: [.skipsHiddenFiles], errorHandler: { _, error in
                enumerationError = error
                return false
            }) else { throw ImportError.invalidSelection }
            for case let item as URL in enumerator {
                let info = try item.resourceValues(forKeys: properties)
                if info.isSymbolicLink == true { continue }
                if info.isDirectory == true {
                    if ignoredDirectories.contains(item.lastPathComponent) || excludedName(item) { enumerator.skipDescendants() }
                    continue
                }
                guard info.isRegularFile == true, allowed(item) else { continue }
                // Enumeration depth avoids macOS /var and /private/var URL alias differences.
                let relative = item.pathComponents.suffix(enumerator.level).joined(separator: "/")
                let target = config.appendingPathComponent(relative)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: item, to: target)
            }
            if let enumerationError { throw enumerationError }
        }
        let rootFiles = try manager.contentsOfDirectory(at: config, includingPropertiesForKeys: nil)
        let keymaps = rootFiles.filter { $0.pathExtension == "keymap" }
        guard !keymaps.isEmpty else { throw ImportError.missingKeymap }
        let names = Set(keymaps.map(\.lastPathComponent))
        if !names.contains("glove80.keymap") && !names.isSuperset(of: ["glove80_lh.keymap", "glove80_rh.keymap"]) {
            guard keymaps.count == 1 else { throw ImportError.unsupportedKeymaps }
            try manager.moveItem(at: keymaps[0], to: config.appendingPathComponent("glove80.keymap"))
        }
        let defaults = repository.appendingPathComponent("config/\(profile.rawValue)", isDirectory: true)
        for name in ["west.yml", "glove80.conf"] {
            let file = config.appendingPathComponent(name)
            if !manager.fileExists(atPath: file.path) {
                try manager.copyItem(at: defaults.appendingPathComponent(name), to: file)
            }
        }
        completed = true
        return ImportedConfiguration(directory: destination)
    }
}
