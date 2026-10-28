import AppKit
import Foundation

final class FlasherController: NSObject, NSApplicationDelegate {
    private enum Side: String, Hashable {
        case left
        case right

        var volumeName: String {
            switch self {
            case .left: return "GLV80LHBOOT"
            case .right: return "GLV80RHBOOT"
            }
        }

        var firmwareName: String {
            switch self {
            case .left: return "glove80_lh-zmk.uf2"
            case .right: return "glove80_rh-zmk.uf2"
            }
        }

        var shortDestinationName: String {
            switch self {
            case .left: return "L.UF2"
            case .right: return "R.UF2"
            }
        }
    }

    private struct FirmwareBuildStatus: Decodable {
        let status: String
        let sourceCommit: String
        let runURL: String?

        enum CodingKeys: String, CodingKey {
            case status
            case sourceCommit = "source_commit"
            case runURL = "run_url"
        }
    }

    private enum BuildReadiness {
        case ready(sourceCommit: String)
        case pending(sourceCommit: String)
        case failed(sourceCommit: String, runURL: String?)
        case unavailable(sourceCommit: String?)
    }

    private let fileManager = FileManager.default
    private var window: NSWindow!
    private var commitLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var leftStatus: NSTextField!
    private var rightStatus: NSTextField!
    private var pullButton: NSButton!
    private var restoreButton: NSButton!
    private var factoryButton: NSButton!
    private var chargeGuardButton: NSButton!
    private var chargeGuardSettingsController: ChargeGuardSettingsController?
    private var timer: Timer?
    private var buildRetryTimer: Timer?
    private var repoRoot: URL?
    private var activeFirmwareRoot: URL?
    private var firmwareReady = false
    private var pullInProgress = false
    private var flashed: Set<Side> = []
    private var flashing: Set<Side> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let iconURL = appBundleURL()?
            .appendingPathComponent("Contents/Resources/AppIcon.icns")
        if let iconURL,
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        buildWindow()
        repoRoot = findRepoRoot()

        guard let repoRoot else {
            pullButton.isEnabled = false
            restoreButton.isEnabled = false
            factoryButton.isEnabled = false
            chargeGuardButton.isEnabled = false
            commitLabel.stringValue = "Repository unavailable"
            statusLabel.stringValue = "Could not find the repo firmware/ folder. Keep this app inside the glove80-mac checkout."
            statusLabel.textColor = .systemRed
            return
        }

        refreshRepositoryState(in: repoRoot, resetFlashCycleIfReady: false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Glove80 Flasher"
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 24, left: 32, bottom: 24, right: 32)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = label("Glove80 Flasher", size: 26, weight: .bold)

        commitLabel = label("Checking repository and firmware build…", size: 11, weight: .regular)
        commitLabel.textColor = .secondaryLabelColor
        configureWrapping(commitLabel, maxWidth: 640)
        NSLayoutConstraint.activate([
            commitLabel.widthAnchor.constraint(equalToConstant: 640),
            commitLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 34)
        ])

        pullButton = NSButton(title: "Pull Repo", target: self, action: #selector(pullRepo))
        pullButton.bezelStyle = .rounded
        pullButton.controlSize = .regular
        pullButton.keyEquivalent = "r"
        pullButton.keyEquivalentModifierMask = [.command]

        chargeGuardButton = NSButton(
            title: "Charge Guard Settings…",
            target: self,
            action: #selector(openChargeGuardSettings)
        )
        chargeGuardButton.bezelStyle = .rounded
        chargeGuardButton.controlSize = .regular

        let topButtons = NSStackView(views: [pullButton, chargeGuardButton])
        topButtons.orientation = .horizontal
        topButtons.alignment = .centerY
        topButtons.spacing = 10

        let leftCard = makeCard(
            side: .left,
            title: "Step 1 · Left half",
            instruction: "Enter left bootloader",
            detail: "Wait for GLV80LHBOOT"
        )
        leftStatus = leftCard.status

        let rightCard = makeCard(
            side: .right,
            title: "Step 2 · Right half",
            instruction: "Enter right bootloader",
            detail: "Wait for GLV80RHBOOT"
        )
        rightStatus = rightCard.status

        let cards = NSStackView(views: [leftCard.view, rightCard.view])
        cards.orientation = .horizontal
        cards.distribution = .fillEqually
        cards.alignment = .centerY
        cards.spacing = 16
        cards.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cards.widthAnchor.constraint(equalToConstant: 640),
            cards.heightAnchor.constraint(equalToConstant: 190),
            leftCard.view.heightAnchor.constraint(equalTo: cards.heightAnchor),
            rightCard.view.heightAnchor.constraint(equalTo: cards.heightAnchor)
        ])

        let rgbRecovery = label(
            "Use the RGB toggle assigned in your firmware to enable lighting after flashing.",
            size: 10.5,
            weight: .regular
        )
        rgbRecovery.textColor = .secondaryLabelColor
        configureWrapping(rgbRecovery, maxWidth: 300)
        rgbRecovery.alignment = .left

        let fallback = label(
            "Right-half fallback: switch its power off, hold C + PgDn, then switch it back on while still holding the keys.",
            size: 10.5,
            weight: .regular
        )
        fallback.textColor = .secondaryLabelColor
        configureWrapping(fallback, maxWidth: 300)
        fallback.alignment = .left

        let recoveryRow = NSStackView(views: [rgbRecovery, fallback])
        recoveryRow.orientation = .horizontal
        recoveryRow.distribution = .fillEqually
        recoveryRow.alignment = .top
        recoveryRow.spacing = 16
        recoveryRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            recoveryRow.widthAnchor.constraint(equalToConstant: 640),
            recoveryRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 46)
        ])

        statusLabel = label("Starting…", size: 13, weight: .medium)
        configureWrapping(statusLabel, maxWidth: 410)
        statusLabel.alignment = .left

        restoreButton = NSButton(
            title: "Restore Previous Firmware",
            target: self,
            action: #selector(restorePreviousFirmware)
        )
        restoreButton.bezelStyle = .rounded
        restoreButton.controlSize = .regular

        factoryButton = NSButton(
            title: "Restore Factory Firmware",
            target: self,
            action: #selector(restoreFactoryFirmware)
        )
        factoryButton.bezelStyle = .rounded
        factoryButton.controlSize = .regular

        let recoveryButtons = NSStackView(views: [restoreButton, factoryButton])
        recoveryButtons.orientation = .vertical
        recoveryButtons.alignment = .trailing
        recoveryButtons.spacing = 6
        recoveryButtons.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(statusLabel)
        footer.addSubview(recoveryButtons)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            footer.widthAnchor.constraint(equalToConstant: 640),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 74),
            statusLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: recoveryButtons.leadingAnchor, constant: -16),
            recoveryButtons.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            recoveryButtons.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
            factoryButton.widthAnchor.constraint(equalTo: restoreButton.widthAnchor)
        ])

        root.addArrangedSubview(title)
        root.setCustomSpacing(6, after: title)
        root.addArrangedSubview(commitLabel)
        root.setCustomSpacing(8, after: commitLabel)
        root.addArrangedSubview(topButtons)
        root.setCustomSpacing(18, after: topButtons)
        root.addArrangedSubview(cards)
        root.setCustomSpacing(8, after: cards)
        root.addArrangedSubview(recoveryRow)
        root.setCustomSpacing(10, after: recoveryRow)
        root.addArrangedSubview(footer)

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor)
        ])

        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeCard(
        side: Side,
        title: String,
        instruction: String,
        detail: String
    ) -> (view: NSView, status: NSTextField) {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false

        let name = label(title, size: 16, weight: .semibold)
        let keys = label(instruction, size: 18, weight: .bold)
        let detailLabel = label(detail, size: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor

        let status = label("Waiting", size: 12, weight: .medium)
        status.textColor = .secondaryLabelColor

        stack.addArrangedSubview(name)
        stack.addArrangedSubview(keys)
        stack.addArrangedSubview(detailLabel)
        stack.setCustomSpacing(14, after: detailLabel)
        stack.addArrangedSubview(status)

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(greaterThanOrEqualTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -14)
        ])

        return (card, status)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.alignment = .center
        field.isSelectable = false
        return field
    }

    private func configureWrapping(_ field: NSTextField, maxWidth: CGFloat) {
        field.alignment = .center
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = maxWidth
        field.cell?.wraps = true
        field.cell?.isScrollable = false
    }

    private func firmwareExists(in root: URL) -> Bool {
        firmwarePairExists(in: root.appendingPathComponent("firmware"))
    }

    private func firmwarePairExists(in firmwareRoot: URL) -> Bool {
        let left = firmwareRoot.appendingPathComponent("glove80_lh-zmk.uf2")
        let right = firmwareRoot.appendingPathComponent("glove80_rh-zmk.uf2")
        return fileManager.fileExists(atPath: left.path) && fileManager.fileExists(atPath: right.path)
    }

    private func runGit(_ arguments: [String], in root: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return output.isEmpty ? nil : output
        } catch {
            return nil
        }
    }

    private func previousSuccessfulFirmwareBuild(in root: URL) -> String? {
        guard let log = runGit(["log", "--format=%H%x09%an%x09%ae", "-n", "100"], in: root) else {
            return nil
        }

        var successfulBuilds: [String] = []
        for line in log.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }

            let hash = String(parts[0])
            let author = String(parts[1])
            let email = String(parts[2])
            guard author == "github-actions[bot]"
                    || email == "41898282+github-actions[bot]@users.noreply.github.com" else {
                continue
            }

            guard let statusJSON = runGit(
                ["show", "\(hash):firmware/build-status.json"],
                in: root
            ),
            let data = statusJSON.data(using: .utf8),
            let status = try? JSONDecoder().decode(FirmwareBuildStatus.self, from: data),
            status.status == "success" else {
                continue
            }

            successfulBuilds.append(hash)
            if successfulBuilds.count == 2 {
                return successfulBuilds[1]
            }
        }

        return nil
    }

    private func extractFirmware(
        named name: String,
        from commit: String,
        in root: URL,
        to destination: URL
    ) -> Bool {
        guard fileManager.createFile(atPath: destination.path, contents: nil),
              let output = try? FileHandle(forWritingTo: destination) else {
            return false
        }
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "show", "\(commit):firmware/\(name)"]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                try? fileManager.removeItem(at: destination)
                return false
            }
            return true
        } catch {
            try? fileManager.removeItem(at: destination)
            return false
        }
    }

    private func prepareFirmwareBuild(_ commit: String, in root: URL) -> URL? {
        let firmwareRoot = fileManager.temporaryDirectory
            .appendingPathComponent("Glove80Flasher", isDirectory: true)
            .appendingPathComponent(commit, isDirectory: true)

        try? fileManager.removeItem(at: firmwareRoot)
        do {
            try fileManager.createDirectory(
                at: firmwareRoot,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        for side in [Side.left, Side.right] {
            let destination = firmwareRoot.appendingPathComponent(side.firmwareName)
            guard extractFirmware(
                named: side.firmwareName,
                from: commit,
                in: root,
                to: destination
            ) else {
                try? fileManager.removeItem(at: firmwareRoot)
                return nil
            }
        }

        return firmwareRoot
    }

    private func latestSourceCommit(in root: URL) -> String? {
        guard let log = runGit(["log", "--format=%H%x09%an%x09%s", "-n", "40"], in: root) else {
            return nil
        }

        for line in log.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }

            let hash = String(parts[0])
            let author = String(parts[1])
            if author == "github-actions[bot]" {
                continue
            }

            return hash
        }

        return nil
    }

    private func readBuildStatus(in root: URL) -> FirmwareBuildStatus? {
        let statusURL = root.appendingPathComponent("firmware/build-status.json")
        guard let data = try? Data(contentsOf: statusURL) else { return nil }
        return try? JSONDecoder().decode(FirmwareBuildStatus.self, from: data)
    }

    private func buildReadiness(in root: URL) -> BuildReadiness {
        let sourceCommit = latestSourceCommit(in: root)
        let status = readBuildStatus(in: root)

        if let sourceCommit, let status {
            if status.sourceCommit == sourceCommit {
                if status.status == "success", firmwareExists(in: root) {
                    return .ready(sourceCommit: sourceCommit)
                }
                if status.status == "failed" {
                    return .failed(sourceCommit: sourceCommit, runURL: status.runURL)
                }
                return .unavailable(sourceCommit: sourceCommit)
            }

            return .pending(sourceCommit: sourceCommit)
        }

        // A host-tools checkout can flash a firmware pair supplied by the user.
        // Repositories with a firmware build retain source/status matching above.
        if let sourceCommit, !fileManager.fileExists(atPath: root.appendingPathComponent("config/west.yml").path),
           firmwareExists(in: root) {
            return .ready(sourceCommit: sourceCommit)
        }

        if let sourceCommit {
            return .pending(sourceCommit: sourceCommit)
        }

        return .unavailable(sourceCommit: nil)
    }

    private func shortHash(_ hash: String) -> String {
        String(hash.prefix(7))
    }

    private func refreshRepositoryState(in root: URL, resetFlashCycleIfReady: Bool) {
        let head = runGit(["rev-parse", "--short", "HEAD"], in: root) ?? "unknown"
        let subject = runGit(["log", "-1", "--format=%s", "HEAD"], in: root) ?? "Description unavailable"
        let commitDescription = "Latest commit \(head): \(subject)"

        switch buildReadiness(in: root) {
        case .ready(let sourceCommit):
            firmwareReady = true
            stopBuildRetrying()
            commitLabel.textColor = .secondaryLabelColor
            commitLabel.stringValue = "\(commitDescription)\nPrebuilt firmware ✓  •  source \(shortHash(sourceCommit))"

            if resetFlashCycleIfReady {
                resetFlashCycle()
            }

            statusLabel.textColor = .labelColor
            statusLabel.stringValue = "✓ Firmware build is complete. Step 1: connect the left half by USB and enter bootloader mode."
            startMonitoring()

        case .pending(let sourceCommit):
            firmwareReady = false
            stopMonitoring()
            commitLabel.textColor = .systemOrange
            commitLabel.stringValue = "\(commitDescription)\nSource \(shortHash(sourceCommit)) is waiting for its firmware build"
            update(.left, text: "Build pending", color: .systemOrange)
            update(.right, text: "Build pending", color: .systemOrange)
            statusLabel.textColor = .systemOrange
            statusLabel.stringValue = "Firmware is still building. Checking automatically every 15 seconds…"
            startBuildRetrying()

        case .failed(let sourceCommit, _):
            firmwareReady = false
            stopMonitoring()
            commitLabel.textColor = .systemRed
            commitLabel.stringValue = "\(commitDescription)\nFirmware build ✕  •  source \(shortHash(sourceCommit))"
            update(.left, text: "Build failed", color: .systemRed)
            update(.right, text: "Build failed", color: .systemRed)
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Firmware build failed. Fix or rerun the GitHub Actions build; checking will continue automatically."
            startBuildRetrying()

        case .unavailable(let sourceCommit):
            firmwareReady = false
            stopMonitoring()
            commitLabel.textColor = .systemOrange
            if let sourceCommit {
                commitLabel.stringValue = "\(commitDescription)\nFirmware build status unavailable  •  source \(shortHash(sourceCommit))"
            } else {
                commitLabel.stringValue = "\(commitDescription)\nFirmware build status unavailable"
            }
            update(.left, text: "Not ready", color: .systemOrange)
            update(.right, text: "Not ready", color: .systemOrange)
            statusLabel.textColor = .systemOrange
            statusLabel.stringValue = "Firmware build status is unavailable. Checking automatically every 15 seconds…"
            startBuildRetrying()
        }
    }

    @objc private func openChargeGuardSettings() {
        guard let repoRoot else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Could not find the glove80-mac checkout for Charge Guard settings."
            return
        }

        if let controller = chargeGuardSettingsController {
            controller.show()
            return
        }

        let controller = ChargeGuardSettingsController(repoRoot: repoRoot)
        chargeGuardSettingsController = controller
        controller.show()
    }

    @objc private func pullRepo() {
        performPull(automatic: false)
    }

    @objc private func restorePreviousFirmware() {
        guard let repoRoot else { return }
        guard flashing.isEmpty else {
            statusLabel.textColor = .systemOrange
            statusLabel.stringValue = "Wait for the current flash to finish before selecting recovery firmware."
            return
        }

        guard let commit = previousSuccessfulFirmwareBuild(in: repoRoot),
              let firmwareRoot = prepareFirmwareBuild(commit, in: repoRoot) else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Could not load the previous successful GitHub Actions firmware build."
            return
        }

        activeFirmwareRoot = firmwareRoot
        firmwareReady = true
        stopBuildRetrying()
        resetFlashCycle()
        commitLabel.textColor = .systemGreen
        commitLabel.stringValue = "Recovery firmware selected\nPrevious successful GitHub Actions build \(shortHash(commit)) ✓"
        statusLabel.textColor = .labelColor
        statusLabel.stringValue = "Previous firmware ready. Flash the left half, then the right half."
        restoreButton.title = "Previous Firmware Selected"
        restoreButton.isEnabled = false
        factoryButton.title = "Restore Factory Firmware"
        factoryButton.isEnabled = true
        startMonitoring()
    }

    @objc private func restoreFactoryFirmware() {
        guard let repoRoot else { return }
        guard flashing.isEmpty else {
            statusLabel.textColor = .systemOrange
            statusLabel.stringValue = "Wait for the current flash to finish before selecting factory firmware."
            return
        }

        let factoryRoot = repoRoot.appendingPathComponent("firmware/factory")
        guard firmwarePairExists(in: factoryRoot) else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "The repository's static factory firmware pair is unavailable."
            return
        }

        activeFirmwareRoot = factoryRoot
        firmwareReady = true
        stopBuildRetrying()
        resetFlashCycle()
        commitLabel.textColor = .systemGreen
        commitLabel.stringValue = "Factory recovery selected\nStatic MoErgo factory firmware ✓"
        statusLabel.textColor = .labelColor
        statusLabel.stringValue = "Factory firmware ready. Flash both halves, then factory-reset and re-pair them."
        restoreButton.title = "Restore Previous Firmware"
        restoreButton.isEnabled = true
        factoryButton.title = "Factory Firmware Selected"
        factoryButton.isEnabled = false
        startMonitoring()
    }

    private func performPull(automatic: Bool) {
        guard let repoRoot else {
            statusLabel.stringValue = "Could not find the glove80-mac checkout."
            statusLabel.textColor = .systemRed
            return
        }

        guard flashing.isEmpty else {
            statusLabel.stringValue = "Wait for the current flash to finish before pulling new firmware."
            statusLabel.textColor = .systemOrange
            return
        }

        guard !pullInProgress else { return }

        let previousHead = runGit(["rev-parse", "HEAD"], in: repoRoot)

        pullInProgress = true
        pullButton.isEnabled = false
        statusLabel.textColor = .labelColor
        statusLabel.stringValue = automatic ? "Checking for completed firmware…" : "Pulling latest repo changes…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repoRoot.path, "pull", "--ff-only", "origin", "main"]

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            do {
                try process.run()
                process.waitUntilExit()
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                DispatchQueue.main.async {
                    self.pullInProgress = false
                    self.pullButton.isEnabled = true

                    if process.terminationStatus == 0 {
                        let newHead = self.runGit(["rev-parse", "HEAD"], in: repoRoot)
                        let repoChanged = previousHead != newHead
                        let wasRestoring = self.activeFirmwareRoot != nil
                        self.activeFirmwareRoot = nil
                        self.restoreButton.title = "Restore Previous Firmware"
                        self.restoreButton.isEnabled = true
                        self.factoryButton.title = "Restore Factory Firmware"
                        self.factoryButton.isEnabled = true
                        self.refreshRepositoryState(
                            in: repoRoot,
                            resetFlashCycleIfReady: repoChanged || wasRestoring
                        )
                    } else {
                        self.statusLabel.textColor = automatic ? .systemOrange : .systemRed
                        let lastLine = output.split(separator: "\n").last.map(String.init) ?? "git pull failed"
                        self.statusLabel.stringValue = automatic
                            ? "Automatic check failed; trying again in 15 seconds."
                            : "Pull failed: \(lastLine)"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.pullInProgress = false
                    self.pullButton.isEnabled = true
                    self.statusLabel.textColor = automatic ? .systemOrange : .systemRed
                    self.statusLabel.stringValue = automatic
                        ? "Automatic check failed; trying again in 15 seconds."
                        : "Pull failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func startBuildRetrying() {
        buildRetryTimer?.invalidate()
        buildRetryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.performPull(automatic: true)
        }
    }

    private func stopBuildRetrying() {
        buildRetryTimer?.invalidate()
        buildRetryTimer = nil
    }

    private func resetFlashCycle() {
        flashed.removeAll()
        flashing.removeAll()
        update(.left, text: "Waiting", color: .secondaryLabelColor)
        update(.right, text: "Waiting", color: .secondaryLabelColor)
    }

    private func startMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.scanVolumes()
        }
        scanVolumes()
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func scanVolumes() {
        guard repoRoot != nil, firmwareReady else { return }
        let volumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []

        for side in [Side.left, Side.right] {
            guard !flashed.contains(side), !flashing.contains(side) else { continue }
            if let volume = volumes.first(where: { $0.lastPathComponent == side.volumeName }) {
                flash(side, to: volume)
            }
        }
    }

    private func flash(_ side: Side, to volume: URL) {
        guard let repoRoot, firmwareReady else { return }
        flashing.insert(side)
        update(side, text: "Flashing…", color: .systemOrange)
        statusLabel.stringValue = "Detected \(side.volumeName). Copying \(side.rawValue)-half firmware…"

        let sourceRoot = activeFirmwareRoot ?? repoRoot.appendingPathComponent("firmware")
        let source = sourceRoot.appendingPathComponent(side.firmwareName)
        let destination = volume.appendingPathComponent(side.shortDestinationName)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var copySucceeded = false

            do {
                if self.fileManager.fileExists(atPath: destination.path) {
                    try self.fileManager.removeItem(at: destination)
                }
                try self.fileManager.copyItem(at: source, to: destination)
                copySucceeded = true
            } catch {
                Thread.sleep(forTimeInterval: 0.8)
                if !self.fileManager.fileExists(atPath: volume.path) {
                    copySucceeded = true
                } else {
                    DispatchQueue.main.async {
                        self.flashing.remove(side)
                        self.update(side, text: "Copy failed", color: .systemRed)
                        self.statusLabel.stringValue = "Could not flash the \(side.rawValue) half: \(error.localizedDescription)"
                        self.statusLabel.textColor = .systemRed
                    }
                    return
                }
            }

            if copySucceeded {
                for _ in 0..<40 {
                    if !self.fileManager.fileExists(atPath: volume.path) { break }
                    Thread.sleep(forTimeInterval: 0.2)
                }

                DispatchQueue.main.async {
                    self.flashing.remove(side)
                    self.flashed.insert(side)
                    self.update(side, text: "✓ Flashed", color: .systemGreen)
                    self.refreshOverallStatus()
                }
            }
        }
    }

    private func refreshOverallStatus() {
        statusLabel.textColor = .labelColor
        if flashed.count == 2 {
            statusLabel.stringValue = "✓ Both halves are flashed."
            NSSound(named: NSSound.Name("Glass"))?.play()
        } else if flashed.contains(.left) {
            statusLabel.stringValue = "Step 1 complete. Step 2: enter the right-half bootloader."
        } else if flashed.contains(.right) {
            statusLabel.stringValue = "Step 2 complete. Step 1 still needs the left half: enter its bootloader."
        }
    }

    private func update(_ side: Side, text: String, color: NSColor) {
        let field = side == .left ? leftStatus : rightStatus
        field?.stringValue = text
        field?.textColor = color
    }

    private func appBundleURL() -> URL? {
        var candidate = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        for _ in 0..<6 {
            if candidate.pathExtension == "app" {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }

        return Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil
    }

    private func findRepoRoot() -> URL? {
        if let path = ProcessInfo.processInfo.environment["GLOVE80_REPO_ROOT"] {
            let root = URL(fileURLWithPath: path)
            if fileManager.fileExists(atPath: root.appendingPathComponent("firmware").path) {
                return root
            }
        }
        var candidate = (appBundleURL() ?? Bundle.main.bundleURL).deletingLastPathComponent()
        for _ in 0..<8 {
            let firmware = candidate.appendingPathComponent("firmware")
            if fileManager.fileExists(atPath: firmware.path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { break }
            candidate = parent
        }
        return nil
    }
}

@main
struct Glove80FlasherApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = FlasherController()
        app.delegate = delegate
        app.run()
    }
}
