import AppKit
import Foundation

final class ChargeGuardSettingsController: NSObject, NSWindowDelegate {
    private let repoRoot: URL
    private let fileManager = FileManager.default

    private var window: NSWindow!
    private var enabledCheckbox: NSButton!
    private var fullChargeButton: NSButton!
    private var chargeLimitField: NSTextField!
    private var resumeLevelField: NSTextField!
    private var pollSecondsField: NSTextField!
    private var leftUSBPort: NSPopUpButton!
    private var rightUSBPort: NSPopUpButton!
    private var usbChoicesLoaded = false
    private var leftBatteryLabel: NSTextField!
    private var rightBatteryLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var statusTimer: Timer?
    private var applyButton: NSButton!
    private var refreshButton: NSButton!

    private var appSupportURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Glove80 Mac", isDirectory: true)
    }

    private var configURL: URL {
        appSupportURL.appendingPathComponent("ChargeGuardConfig.plist")
    }

    private var launchAgentURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/io.github.JFWooten4.glove80-mac-charge-guard.plist")
    }

    private var helperURL: URL {
        appSupportURL.appendingPathComponent("Glove80ChargeGuard")
    }

    init(repoRoot: URL) {
        self.repoRoot = repoRoot
        super.init()
        buildWindow()
        loadSettings()
        refreshStatus()
        refreshUSBPorts()
    }

    func show() {
        loadSettings()
        refreshStatus()
        startStatusTimer()
        refreshUSBPorts()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Glove80 Charge Guard"
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.delegate = self

        let title = label("Charge Guard", size: 22, weight: .bold)
        let explanation = label(
            "Limit Glove80 charging by switching mapped USB power off at the cutoff threshold and restoring it at the resume threshold.",
            size: 11.5,
            weight: .regular
        )
        explanation.textColor = .secondaryLabelColor
        explanation.alignment = .left
        configureWrapping(explanation, width: 440)

        enabledCheckbox = NSButton(
            checkboxWithTitle: "Enable automatic charging cutoff",
            target: nil,
            action: nil
        )

        fullChargeButton = NSButton(
            title: "Full Charge to 100%",
            target: self,
            action: #selector(toggleFullCharge)
        )
        fullChargeButton.setButtonType(.pushOnPushOff)
        fullChargeButton.bezelStyle = .rounded
        fullChargeButton.toolTip = "Temporarily bypass the charge limit. This turns itself off after all visible Glove80 batteries reach 100%."

        leftBatteryLabel = label("Left: —", size: 17, weight: .semibold)
        rightBatteryLabel = label("Right: —", size: 17, weight: .semibold)
        let batteryRow = NSStackView(views: [leftBatteryLabel, rightBatteryLabel])
        batteryRow.orientation = .horizontal
        batteryRow.alignment = .centerY
        batteryRow.spacing = 32

        chargeLimitField = numberField()
        resumeLevelField = numberField()
        pollSecondsField = numberField()

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.addArrangedSubview(makeRow("Stop charging at", field: chargeLimitField, suffix: "%"))
        form.addArrangedSubview(makeRow("Resume charging at", field: resumeLevelField, suffix: "%"))
        form.addArrangedSubview(makeRow("Check battery every", field: pollSecondsField, suffix: "seconds"))

        leftUSBPort = NSPopUpButton(frame: .zero, pullsDown: false)
        rightUSBPort = NSPopUpButton(frame: .zero, pullsDown: false)
        for popup in [leftUSBPort!, rightUSBPort!] {
            popup.addItem(withTitle: "Auto-detect")
            popup.lastItem?.representedObject = ""
            popup.widthAnchor.constraint(equalToConstant: 270).isActive = true
        }
        for (title, popup) in [("Left charging port", leftUSBPort!), ("Right charging port", rightUSBPort!)] {
            let row = NSStackView(views: [label(title, size: 12, weight: .medium), popup])
            row.orientation = .horizontal
            row.spacing = 8
            form.addArrangedSubview(row)
        }

        let hardwareNote = label(
            "At the cutoff, Charge Guard requests USB power off so the keyboard can discharge while continuing over Bluetooth. USB data cannot stay active without VBUS on normal ports. If the current port cannot switch VBUS, use a compatible switched hub or unplug that charging lead.",
            size: 10.5,
            weight: .regular
        )
        hardwareNote.textColor = .secondaryLabelColor
        hardwareNote.alignment = .left
        configureWrapping(hardwareNote, width: 440)

        statusLabel = label("Loading Charge Guard status…", size: 11, weight: .regular)
        statusLabel.alignment = .left
        statusLabel.isSelectable = true
        configureWrapping(statusLabel, width: 440)

        applyButton = NSButton(title: "Apply Settings", target: self, action: #selector(applySettings))
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"

        refreshButton = NSButton(title: "Refresh Status", target: self, action: #selector(refreshStatusAction))
        refreshButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [refreshButton, applyButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 24, left: 36, bottom: 24, right: 36)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(title)
        root.setCustomSpacing(6, after: title)
        root.addArrangedSubview(explanation)
        root.setCustomSpacing(16, after: explanation)
        root.addArrangedSubview(enabledCheckbox)
        root.setCustomSpacing(6, after: enabledCheckbox)
        root.addArrangedSubview(fullChargeButton)
        root.setCustomSpacing(8, after: fullChargeButton)
        root.addArrangedSubview(batteryRow)
        root.setCustomSpacing(12, after: batteryRow)
        root.addArrangedSubview(form)
        root.setCustomSpacing(4, after: form)
        root.addArrangedSubview(hardwareNote)
        root.setCustomSpacing(6, after: hardwareNote)
        root.addArrangedSubview(statusLabel)
        root.addArrangedSubview(buttons)

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor)
        ])
        window.contentView = content
    }

    private func makeRow(_ title: String, field: NSTextField, suffix: String) -> NSView {
        let titleLabel = label(title, size: 12, weight: .medium)
        titleLabel.alignment = .left
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: 165).isActive = true

        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let suffixLabel = label(suffix, size: 12, weight: .regular)
        suffixLabel.textColor = .secondaryLabelColor
        suffixLabel.alignment = .left

        let row = NSStackView(views: [titleLabel, field, suffixLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func numberField() -> NSTextField {
        let field = NSTextField(string: "")
        field.alignment = .right
        field.formatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .none
            formatter.allowsFloats = false
            formatter.minimum = 0
            formatter.maximum = 9999
            return formatter
        }()
        return field
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        return field
    }

    private func configureWrapping(_ field: NSTextField, width: CGFloat) {
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = width
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func loadSettings() {
        let config = readPlist(at: configURL)
        let launchAgent = readPlist(at: launchAgentURL)
        let environment = launchAgent?["EnvironmentVariables"] as? [String: Any]

        let enabled = boolValue(config?["Enabled"])
            ?? fileManager.fileExists(atPath: launchAgentURL.path)
        let chargeLimit = intValue(config?["ChargeLimit"])
            ?? intValue(environment?["GLOVE80_CHARGE_LIMIT"])
            ?? 80
        let resumeLevel = intValue(config?["ResumeLevel"])
            ?? intValue(environment?["GLOVE80_CHARGE_RESUME"])
            ?? 70
        let pollSeconds = intValue(config?["PollSeconds"])
            ?? intValue(environment?["GLOVE80_CHARGE_POLL_SECONDS"])
            ?? 60

        enabledCheckbox.state = enabled ? .on : .off
        fullChargeButton.state = boolValue(config?["FullCharge"]) == true ? .on : .off
        chargeLimitField.stringValue = String(chargeLimit)
        resumeLevelField.stringValue = String(resumeLevel)
        pollSecondsField.stringValue = String(pollSeconds)
    }

    private func readPlist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let dictionary = propertyList as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return ["1", "true", "yes"].contains(string.lowercased())
        }
        return nil
    }

    @objc private func applySettings() {
        guard let chargeLimit = Int(chargeLimitField.stringValue),
              (1...100).contains(chargeLimit) else {
            showError("The cutoff must be an integer from 1 to 100.")
            return
        }

        guard let resumeLevel = Int(resumeLevelField.stringValue),
              resumeLevel >= 0,
              resumeLevel < chargeLimit else {
            showError("The resume level must be zero or greater and lower than the cutoff.")
            return
        }

        guard let pollSeconds = Int(pollSecondsField.stringValue),
              pollSeconds >= 15 else {
            showError("The polling interval must be at least 15 seconds.")
            return
        }

        let installer = repoRoot.appendingPathComponent("macOS/install-charge-guard.sh")
        guard fileManager.fileExists(atPath: installer.path) else {
            showError("Could not find macOS/install-charge-guard.sh in the repository.")
            return
        }

        let shouldEnable = enabledCheckbox.state == .on
        applyButton.isEnabled = false
        refreshButton.isEnabled = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = shouldEnable
            ? "Applying Charge Guard settings…"
            : "Disabling Charge Guard…"

        var environment = ProcessInfo.processInfo.environment
        environment["GLOVE80_CHARGE_LIMIT"] = String(chargeLimit)
        environment["GLOVE80_CHARGE_RESUME"] = String(resumeLevel)
        environment["GLOVE80_CHARGE_POLL_SECONDS"] = String(pollSeconds)
        environment["GLOVE80_FULL_CHARGE"] = fullChargeButton.state == .on ? "true" : "false"
        let left = leftUSBPort.selectedItem?.representedObject as? String ?? ""
        let right = rightUSBPort.selectedItem?.representedObject as? String ?? ""
        if shouldEnable && (!left.isEmpty || !right.isEmpty) &&
            (left.isEmpty || right.isEmpty || left == right) {
            applyButton.isEnabled = true
            refreshButton.isEnabled = true
            showError("Select two distinct charging ports, or choose Auto-detect for both halves.")
            return
        }
        environment["GLOVE80_USB_PORTS"] = left.isEmpty ? "" : "\(left),\(right)"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let arguments = shouldEnable ? [installer.path] : [installer.path, "--disable"]
            let result = self.runProcess(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: arguments,
                environment: environment
            )

            DispatchQueue.main.async {
                self.applyButton.isEnabled = true
                self.refreshButton.isEnabled = true

                if result.status == 0 {
                    self.statusLabel.textColor = .labelColor
                    self.loadSettings()
                    self.refreshStatus()
                } else {
                    self.statusLabel.textColor = .systemRed
                    let message = result.output
                        .split(separator: "\n")
                        .last
                        .map(String.init)
                        ?? "Charge Guard settings could not be applied."
                    self.statusLabel.stringValue = message
                }
            }
        }
    }

    @objc private func toggleFullCharge() {
        let shouldEnable = fullChargeButton.state == .on

        guard fileManager.fileExists(atPath: helperURL.path) else {
            fullChargeButton.state = shouldEnable ? .off : .on
            showError("Apply Charge Guard settings first so the helper is installed.")
            return
        }

        fullChargeButton.isEnabled = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = shouldEnable
            ? "Starting a one-time full charge…"
            : "Returning to the normal charge window…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runProcess(
                executable: self.helperURL,
                arguments: [shouldEnable ? "--full-charge" : "--cancel-full-charge"],
                environment: nil
            )

            DispatchQueue.main.async {
                self.fullChargeButton.isEnabled = true
                if result.status == 0 {
                    self.loadSettings()
                    self.refreshStatus()
                } else {
                    self.fullChargeButton.state = shouldEnable ? .off : .on
                    self.statusLabel.textColor = .systemRed
                    self.statusLabel.stringValue = result.output.isEmpty
                        ? "Could not change Full Charge mode."
                        : result.output
                }
            }
        }
    }

    @objc private func refreshStatusAction() {
        refreshStatus()
        refreshUSBPorts()
    }

    private func refreshUSBPorts() {
        guard fileManager.fileExists(atPath: helperURL.path) else { return }
        let saved = (readPlist(at: configURL)?["USBPorts"] as? String ?? "")
            .split(separator: ",").map(String.init)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = self.runProcess(executable: self.helperURL, arguments: ["--usb-status"], environment: nil)
            var location = ""
            var choices: [(String, String)] = []
            for line in result.output.split(separator: "\n").map(String.init) {
                if line.hasPrefix("Current status for hub ") {
                    location = String(line.dropFirst("Current status for hub ".count).split(separator: " ").first ?? "")
                } else {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !location.isEmpty, trimmed.hasPrefix("Port "),
                          let colon = trimmed.firstIndex(of: ":"),
                          let port = Int(trimmed.dropFirst(5).prefix(upTo: colon)) else { continue }
                    let details = String(trimmed[trimmed.index(after: colon)...])
                    let glove = details.localizedCaseInsensitiveContains("Glove80")
                    guard glove || (!details.contains("[") && !details.contains("connect") && !details.contains("enable")) else { continue }
                    let identifier = "\(location):\(port)"
                    let side = details.localizedCaseInsensitiveContains("Right") ? "Right" : "Left"
                    choices.append((identifier, "\(identifier) — \(glove ? "Glove80 " + side : "No USB device")"))
                }
            }
            DispatchQueue.main.async {
                for (index, popup) in [self.leftUSBPort!, self.rightUSBPort!].enumerated() {
                    let selected = popup.selectedItem?.representedObject as? String ?? ""
                    let desired = !self.usbChoicesLoaded && saved.count == 2 ? saved[index] : selected
                    popup.removeAllItems()
                    popup.addItem(withTitle: "Auto-detect")
                    popup.lastItem?.representedObject = ""
                    for (identifier, title) in choices {
                        popup.addItem(withTitle: title)
                        popup.lastItem?.representedObject = identifier
                    }
                    if !desired.isEmpty && !choices.contains(where: { $0.0 == desired }) {
                        popup.addItem(withTitle: "\(desired) — unavailable")
                        popup.lastItem?.representedObject = desired
                    }
                    if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == desired }) {
                        popup.select(item)
                    }
                }
                self.usbChoicesLoaded = true
            }
        }
    }

    private func startStatusTimer() {
        guard statusTimer == nil else { return }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        if let statusTimer {
            RunLoop.main.add(statusTimer, forMode: .common)
        }
    }

    private func updateBatteryLabels(from output: String) {
        var left: Int?
        var right: Int?
        var unsided: Int?

        for line in output.split(separator: "\n").map(String.init)
        where line.hasPrefix("Battery:") {
            let numbers = line.split(whereSeparator: { !$0.isNumber })
            guard let value = numbers.last.flatMap({ Int($0) }) else { continue }
            let lower = line.lowercased()
            if lower.contains("left") || lower.contains("lhs") {
                left = value
            } else if lower.contains("right") || lower.contains("rhs") {
                right = value
            } else if unsided == nil {
                unsided = value
            }
        }

        if left == nil {
            left = unsided
        }

        leftBatteryLabel.stringValue = left.map { "Left: \($0)%" } ?? "Left: —"
        rightBatteryLabel.stringValue = right.map { "Right: \($0)%" } ?? "Right: —"
    }

    private func refreshStatus() {
        let config = readPlist(at: configURL)
        let enabled = boolValue(config?["Enabled"])
            ?? fileManager.fileExists(atPath: launchAgentURL.path)
        fullChargeButton.state = boolValue(config?["FullCharge"]) == true ? .on : .off
        let helperInstalled = fileManager.fileExists(atPath: helperURL.path)
        fullChargeButton.isEnabled = helperInstalled

        guard helperInstalled else {
            leftBatteryLabel.stringValue = "Left: —"
            rightBatteryLabel.stringValue = "Right: —"
            statusLabel.textColor = enabled ? .systemOrange : .secondaryLabelColor
            statusLabel.stringValue = enabled
                ? "Enabled in settings, but the Charge Guard helper is not installed yet."
                : "Charge Guard is disabled. Apply settings to install and enable it."
            return
        }

        refreshButton.isEnabled = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = enabled ? "Reading Charge Guard status…" : "Charge Guard is disabled."

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = self.runProcess(
                executable: self.helperURL,
                arguments: ["--status"],
                environment: nil
            )

            DispatchQueue.main.async {
                self.refreshButton.isEnabled = true
                if result.status == 0 {
                    self.updateBatteryLabels(from: result.output)
                    self.statusLabel.textColor = enabled ? .labelColor : .secondaryLabelColor
                    let prefix = enabled ? "Enabled" : "Disabled"
                    let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusLabel.stringValue = output.isEmpty
                        ? prefix
                        : "\(prefix)\n\(output)"
                } else {
                    self.statusLabel.textColor = .systemOrange
                    self.statusLabel.stringValue = result.output.isEmpty
                        ? "Could not read Charge Guard status."
                        : result.output
                }
            }
        }
    }

    private func runProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String]?
    ) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, output)
    }

    private func showError(_ message: String) {
        statusLabel.textColor = .systemRed
        statusLabel.stringValue = message
        NSSound.beep()
    }
}
