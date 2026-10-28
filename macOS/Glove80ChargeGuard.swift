import Foundation

struct BatteryReading: Hashable {
    let name: String
    let level: Int
}

struct ManagedUSBPort: Codable, Hashable {
    let location: String
    let port: Int
    let description: String

    var identifier: String { "\(location):\(port)" }
}

struct ChargeGuardState: Codable {
    var ports: [ManagedUSBPort] = []
    var powerCut = false
    var verifyCutoffAfter: Date?
    var nextCutoffCheck: Date?
}

enum RunMode {
    case watch
    case once
    case status
    case setupUSB
    case usbStatus
    case enableFullCharge
    case disableFullCharge
}

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

final class USBPowerController {
    struct HubPort {
        let location: String
        let port: Int
        let details: String
    }

    private let executable: String

    init?() {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let configured = environment["GLOVE80_UHUBCTL_PATH"], !configured.isEmpty {
            candidates.append(configured)
        }
        candidates += [
            "/opt/homebrew/bin/uhubctl",
            "/usr/local/bin/uhubctl",
            "/opt/local/bin/uhubctl",
            "/usr/sbin/uhubctl",
        ]

        guard let path = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            return nil
        }

        executable = path
    }

    var path: String { executable }

    func status() -> CommandResult {
        run([])
    }

    func discoverGlove80Ports() -> [ManagedUSBPort] {
        let result = status()
        guard result.status == 0 else {
            fputs("Glove80ChargeGuard: uhubctl status failed: \(result.stderr)\n", stderr)
            return []
        }

        let allPorts = parseHubPorts(result.stdout)
        if let configured = parseConfiguredPorts() {
            // Explicit mappings may include a non-enumerating charging lead, but
            // never accept a missing hub port or another enumerated USB device.
            guard configured.allSatisfy({ selected in
                allPorts.contains { candidate in
                    candidate.location == selected.location && candidate.port == selected.port &&
                    (candidate.details.localizedCaseInsensitiveContains("Glove80") ||
                     isPowerOnlyPort(candidate.details))
                }
            }) else {
                fputs("Glove80ChargeGuard: configured USB ports are missing or occupied by another device; map the charging leads again\n", stderr)
                return []
            }
            return configured
        }
        let directMatches = allPorts.filter {
            $0.details.localizedCaseInsensitiveContains("Glove80")
        }

        if directMatches.count >= 2 {
            return uniquePorts(directMatches.map {
                ManagedUSBPort(location: $0.location, port: $0.port, description: $0.details)
            })
        }

        // A powered, non-enumerating port cannot identify a charging lead.
        // Require explicit selection rather than guessing an unrelated port.
        if let direct = directMatches.first {
            return [ManagedUSBPort(location: direct.location, port: direct.port, description: direct.details)]
        }

        return []
    }

    func setPower(_ enabled: Bool, ports: [ManagedUSBPort]) -> Bool {
        guard !ports.isEmpty else {
            return false
        }

        var changed: [ManagedUSBPort] = []
        for port in ports {
            let result = run([
                "-l", port.location,
                "-p", String(port.port),
                "-a", enabled ? "on" : "off",
            ])
            guard result.status == 0 else {
                fputs(
                    "Glove80ChargeGuard: failed to turn \(port.identifier) \(enabled ? "on" : "off"): \(result.stderr)\n",
                    stderr
                )
                if !enabled {
                    for rollback in changed {
                        _ = run([
                            "-l", rollback.location,
                            "-p", String(rollback.port),
                            "-a", "on",
                        ])
                    }
                }
                return false
            }
            changed.append(port)
        }

        return true
    }

    private func parseConfiguredPorts() -> [ManagedUSBPort]? {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Glove80 Mac/ChargeGuardConfig.plist")
        let config = NSDictionary(contentsOf: configURL)
        guard let raw = ProcessInfo.processInfo.environment["GLOVE80_USB_PORTS"]
                ?? config?["USBPorts"] as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var ports: [ManagedUSBPort] = []
        for item in raw.split(separator: ",") {
            let pieces = item.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2, let port = Int(pieces[1]), port > 0 else {
                fputs("Glove80ChargeGuard: invalid GLOVE80_USB_PORTS entry \(item); expected location:port\n", stderr)
                return []
            }
            ports.append(ManagedUSBPort(
                location: pieces[0],
                port: port,
                description: "configured by GLOVE80_USB_PORTS"
            ))
        }
        guard ports.count == 2, uniquePorts(ports).count == 2 else {
            fputs("Glove80ChargeGuard: select two distinct USB charging ports\n", stderr)
            return []
        }
        return ports
    }

    private func parseHubPorts(_ output: String) -> [HubPort] {
        var currentLocation: String?
        var ports: [HubPort] = []

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("Current status for hub ") || line.hasPrefix("New status for hub ") {
                let prefix = line.hasPrefix("Current") ? "Current status for hub " : "New status for hub "
                let remainder = line.dropFirst(prefix.count)
                currentLocation = remainder.split(separator: " ", maxSplits: 1).first.map(String.init)
                continue
            }

            guard let location = currentLocation else {
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Port "), let colon = trimmed.firstIndex(of: ":") else {
                continue
            }

            let portText = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5)..<colon]
            guard let port = Int(portText) else {
                continue
            }

            let detailsStart = trimmed.index(after: colon)
            let details = trimmed[detailsStart...].trimmingCharacters(in: .whitespaces)
            ports.append(HubPort(location: location, port: port, details: details))
        }

        return ports
    }

    private func isPowerOnlyPort(_ details: String) -> Bool {
        let lower = details.lowercased()
        if lower.contains("connect") || lower.contains("enable") {
            return false
        }

        // A bracketed VID:PID identifies an attached device in normal uhubctl output.
        let pattern = #"\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}"#
        return lower.range(of: pattern, options: .regularExpression) == nil
    }

    private func uniquePorts(_ ports: [ManagedUSBPort]) -> [ManagedUSBPort] {
        var seen: Set<String> = []
        return ports.filter { seen.insert($0.identifier).inserted }
    }

    private func run(_ arguments: [String]) -> CommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(status: -1, stdout: "", stderr: String(describing: error))
        }

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}

final class Glove80ChargeGuard {
    private let chargeLimit: Int
    private let resumeLevel: Int
    private let pollInterval: TimeInterval
    private let stateURL: URL
    private let configURL: URL
    private let powerController: USBPowerController?
    private var state: ChargeGuardState
    private var alertedUnavailablePower = false

    init(chargeLimit: Int, resumeLevel: Int, pollInterval: TimeInterval) {
        self.chargeLimit = chargeLimit
        self.resumeLevel = resumeLevel
        self.pollInterval = pollInterval
        self.powerController = USBPowerController()

        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Glove80 Mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.stateURL = support.appendingPathComponent("ChargeGuardState.json")
        self.configURL = support.appendingPathComponent("ChargeGuardConfig.plist")
        self.state = Self.loadState(from: self.stateURL)
    }

    func run(mode: RunMode) -> Int32 {
        switch mode {
        case .setupUSB:
            return setupUSB()
        case .usbStatus:
            return printUSBStatus()
        case .status:
            printStatus()
            return 0
        case .enableFullCharge:
            return setFullChargeMode(true)
        case .disableFullCharge:
            return setFullChargeMode(false)
        case .once, .watch:
            break
        }

        repeat {
            let readings = readBatteryLevels()
            if readings.isEmpty {
                fputs("Glove80ChargeGuard: no host-visible Glove80 battery level found\n", stderr)
            } else {
                for reading in readings.sorted(by: { $0.name < $1.name }) {
                    print("\(reading.name): \(reading.level)%")
                }
            }
            managePower(for: readings)

            if mode != .watch {
                return 0
            }

            Thread.sleep(forTimeInterval: pollInterval)
        } while true
    }

    private func setupUSB() -> Int32 {
        guard let powerController else {
            fputs("Glove80ChargeGuard: uhubctl is not installed; automatic USB power cutoff is unavailable\n", stderr)
            return 2
        }

        guard !state.powerCut else {
            fputs("Glove80ChargeGuard: restore charging with Full Charge before remapping USB ports\n", stderr)
            return 4
        }
        let discovered = powerController.discoverGlove80Ports()
        state.ports = discovered
        saveState()
        guard !discovered.isEmpty else {
            fputs("Glove80ChargeGuard: no controllable Glove80 USB port was found by uhubctl\n", stderr)
            fputs("Glove80ChargeGuard: if the Mac Studio rear ports are not switchable, use a uhubctl-compatible hub\n", stderr)
            return 3
        }

        print("Glove80ChargeGuard: automatic USB power control mapped:")
        for port in discovered {
            print("  \(port.identifier) — \(port.description)")
        }
        if discovered.count == 1 {
            print("Glove80ChargeGuard: only one charging port could be mapped automatically.")
            print("Select both charging ports in Charge Guard settings to manage both halves.")
            return 3
        }
        return 0
    }

    private func printUSBStatus() -> Int32 {
        guard let powerController else {
            print("uhubctl: not installed")
            return 2
        }

        print("uhubctl: \(powerController.path)")
        let result = powerController.status()
        if !result.stdout.isEmpty {
            print(result.stdout, terminator: result.stdout.hasSuffix("\n") ? "" : "\n")
        }
        if !result.stderr.isEmpty {
            fputs(result.stderr, stderr)
        }
        return result.status
    }

    private func printStatus() {
        // Once power is cut, keep the mapping so those ports can be restored.
        // While power is on, report current discovery rather than stale state.
        if !state.powerCut {
            state.ports = powerController?.discoverGlove80Ports() ?? []
        }
        let readings = readBatteryLevels().sorted(by: { $0.name < $1.name })
        if readings.isEmpty {
            print("Battery: no host-visible Glove80 battery level found")
        } else {
            for reading in readings {
                print("Battery: \(reading.name) \(reading.level)%")
            }
        }

        let cutoffStatus: String
        if powerController == nil {
            cutoffStatus = "unavailable (uhubctl not installed)"
        } else if state.ports.count < 2 {
            cutoffStatus = "unavailable (both charging ports must be mapped)"
        } else {
            cutoffStatus = "configured (physical power cutoff needs verification)"
        }
        print("Automatic USB cutoff: \(cutoffStatus)")
        print("Full charge override: \(fullChargeRequested() ? "on" : "off")")
        if state.verifyCutoffAfter != nil {
            print("Battery verification: waiting for USB-free readings (two minutes)")
        }
        print("Charging power command: \(state.powerCut ? "off (physical cutoff unverified)" : "on")")
        if state.ports.isEmpty {
            print("Mapped USB ports: none")
        } else {
            for port in state.ports {
                print("Mapped USB port: \(port.identifier) — \(port.description)")
            }
        }
    }

    private func managePower(for readings: [BatteryReading]) {
        let now = Date()
        let fullCharge = fullChargeRequested()

        // USB power can make the firmware report 100% for a nearly empty battery.
        // Confirm a cutoff only after two normal battery-update intervals off USB.
        if state.powerCut, let deadline = state.verifyCutoffAfter {
            guard now >= deadline else { return }
            guard readings.count >= 2 else {
                restoreChargingPower(level: 0, reason: "Battery verification unavailable; charging restored.")
                return
            }
            let highest = readings.map(\.level).max() ?? 0
            let reached = fullCharge ? readings.allSatisfy { $0.level >= 100 } : highest >= chargeLimit
            if reached {
                state.verifyCutoffAfter = nil
                saveState()
                if fullCharge { setFullChargeRequested(false) }
                notify(title: "Glove80 charge guard", message: "Battery cutoff confirmed without USB power. Charging remains paused.")
                fputs("Glove80ChargeGuard: confirmed battery cutoff at \(highest)% without USB power\n", stderr)
            } else {
                restoreChargingPower(level: highest, reason: "USB-free battery check is below the cutoff; charging restored.")
            }
            return
        }

        guard readings.count >= 2 else { return }
        if !state.powerCut, let powerController {
            let discovered = powerController.discoverGlove80Ports()
            if state.ports != discovered {
                state.ports = discovered
                saveState()
            }
        }

        if fullCharge && state.powerCut {
            _ = restoreChargingPowerForFullCharge()
            return
        }
        if state.powerCut {
            if readings.allSatisfy({ $0.level <= resumeLevel }) {
                restoreChargingPower(level: readings.map(\.level).min() ?? resumeLevel)
            }
            return
        }

        guard now >= (state.nextCutoffCheck ?? .distantPast) else { return }
        let highest = readings.map(\.level).max() ?? 0
        let needsCheck = fullCharge ? readings.allSatisfy { $0.level >= 100 } : highest >= chargeLimit
        if needsCheck { cutChargingPower(level: highest) }
    }

    private func setFullChargeMode(_ enabled: Bool) -> Int32 {
        setFullChargeRequested(enabled)

        if enabled {
            if state.powerCut && !restoreChargingPowerForFullCharge() {
                fputs("Glove80ChargeGuard: Full Charge was enabled, but USB charging power could not be restored\n", stderr)
                return 2
            }
            print("Full Charge enabled. Charging will continue to 100%, then the normal \(resumeLevel)–\(chargeLimit)% window will resume automatically.")
            return 0
        }

        let readings = readBatteryLevels()
        if !readings.isEmpty {
            managePower(for: readings)
        }
        print("Full Charge disabled. The normal \(resumeLevel)–\(chargeLimit)% window is active.")
        return 0
    }

    private func restoreChargingPowerForFullCharge() -> Bool {
        guard let powerController, !state.ports.isEmpty else {
            return false
        }

        guard powerController.setPower(true, ports: state.ports) else {
            return false
        }

        state.powerCut = false
        state.verifyCutoffAfter = nil
        state.nextCutoffCheck = Date().addingTimeInterval(15 * 60)
        saveState()
        alertedUnavailablePower = false
        notify(
            title: "Glove80 charge guard",
            message: "Full Charge enabled. USB charging power was restored until 100%."
        )
        fputs("Glove80ChargeGuard: restored USB charging power for Full Charge\n", stderr)
        return true
    }

    private func fullChargeRequested() -> Bool {
        guard let data = try? Data(contentsOf: configURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let config = propertyList as? [String: Any] else {
            return false
        }

        if let value = config["FullCharge"] as? NSNumber {
            return value.boolValue
        }
        if let value = config["FullCharge"] as? String {
            return ["1", "true", "yes"].contains(value.lowercased())
        }
        return false
    }

    private func setFullChargeRequested(_ enabled: Bool) {
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let propertyList = try? PropertyListSerialization.propertyList(
               from: data,
               options: [],
               format: nil
           ),
           let existing = propertyList as? [String: Any] {
            config = existing
        }

        config["FullCharge"] = enabled

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: config,
                format: .xml,
                options: 0
            )
            try data.write(to: configURL, options: .atomic)
        } catch {
            fputs("Glove80ChargeGuard: could not save Full Charge setting: \(error)\n", stderr)
        }
    }

    private func cutChargingPower(level: Int) {
        guard let powerController, state.ports.count >= 2 else {
            if !alertedUnavailablePower {
                alertedUnavailablePower = true
                notify(
                    title: "Glove80 charge guard",
                    message: "Battery reached \(level)%, but automatic USB power control is unavailable. Connect and map both charging ports in Charge Guard settings."
                )
            }
            return
        }

        guard powerController.setPower(false, ports: state.ports) else {
            notify(
                title: "Glove80 charge guard",
                message: "Battery reached \(level)%, but USB charging power could not be disabled."
            )
            return
        }

        state.powerCut = true
        state.verifyCutoffAfter = Date().addingTimeInterval(120)
        saveState()
        notify(
            title: "Glove80 charge guard",
            message: "Checking battery levels without USB power for two minutes before confirming the cutoff."
        )
        fputs("Glove80ChargeGuard: verifying reported \(level)% with USB power off\n", stderr)
    }

    private func restoreChargingPower(level: Int, reason: String? = nil) {
        guard let powerController, !state.ports.isEmpty else {
            return
        }

        guard powerController.setPower(true, ports: state.ports) else {
            fputs("Glove80ChargeGuard: failed to restore USB charging power\n", stderr)
            return
        }

        state.powerCut = false
        state.verifyCutoffAfter = nil
        state.nextCutoffCheck = Date().addingTimeInterval(15 * 60)
        saveState()
        alertedUnavailablePower = false
        notify(
            title: "Glove80 charge guard",
            message: reason ?? "Battery fell to \(level)%. USB charging power was restored."
        )
        fputs("Glove80ChargeGuard: restored USB charging power at \(level)%\n", stderr)
    }

    private func readBatteryLevels() -> [BatteryReading] {
        let splitLevels = Glove80BatteryReader().read()
        var splitReadings: [BatteryReading] = []

        if let left = splitLevels.left {
            splitReadings.append(BatteryReading(name: "Glove80 Left", level: left))
        }
        if let right = splitLevels.right {
            splitReadings.append(BatteryReading(name: "Glove80 Right", level: right))
        }

        if !splitReadings.isEmpty {
            return splitReadings
        }

        // Fall back to system_profiler for installations that have not flashed
        // firmware with the split Battery Service proxy yet.
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            fputs("Glove80ChargeGuard: failed to run system_profiler: \(error)\n", stderr)
            return []
        }

        guard process.terminationStatus == 0 else {
            fputs("Glove80ChargeGuard: system_profiler exited with status \(process.terminationStatus)\n", stderr)
            return []
        }

        do {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let json = try JSONSerialization.jsonObject(with: data)
            var readings: [String: Int] = [:]
            collectBatteryLevels(from: json, currentDevice: nil, into: &readings)
            return readings.map { BatteryReading(name: $0.key, level: $0.value) }
        } catch {
            fputs("Glove80ChargeGuard: could not parse Bluetooth battery data: \(error)\n", stderr)
            return []
        }
    }

    private func collectBatteryLevels(
        from value: Any,
        currentDevice: String?,
        into readings: inout [String: Int]
    ) {
        if let dictionary = value as? [String: Any] {
            var device = currentDevice

            for (key, child) in dictionary {
                if key.localizedCaseInsensitiveContains("Glove80") {
                    device = key
                }

                if ["device_name", "name", "_name"].contains(key.lowercased()),
                   let name = child as? String,
                   name.localizedCaseInsensitiveContains("Glove80") {
                    device = name
                }
            }

            if let device {
                for (key, child) in dictionary where key.lowercased().contains("battery") {
                    if let level = parseBatteryLevel(child) {
                        let loweredKey = key.lowercased()
                        let suffix: String
                        if loweredKey.contains("right") || loweredKey.contains("rhs") {
                            suffix = " Right"
                        } else if loweredKey.contains("left") || loweredKey.contains("lhs") {
                            suffix = " Left"
                        } else {
                            suffix = ""
                        }
                        readings[device + suffix] = level
                    }
                }
            }

            for child in dictionary.values {
                collectBatteryLevels(from: child, currentDevice: device, into: &readings)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectBatteryLevels(from: child, currentDevice: currentDevice, into: &readings)
            }
        }
    }

    private func parseBatteryLevel(_ value: Any) -> Int? {
        if let number = value as? NSNumber {
            return clamp(number.intValue)
        }

        if let string = value as? String {
            let digits = string.filter(\.isNumber)
            guard let level = Int(digits), !digits.isEmpty else {
                return nil
            }
            return clamp(level)
        }

        return nil
    }

    private func clamp(_ level: Int) -> Int? {
        guard (0...100).contains(level) else {
            return nil
        }
        return level
    }

    private func notify(title: String, message: String) {
        let script = "display notification \(appleScriptString(message)) with title \(appleScriptString(title)) sound name \"Glass\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            fputs("Glove80ChargeGuard: could not post notification: \(error)\n", stderr)
        }
    }

    private func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func saveState() {
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            fputs("Glove80ChargeGuard: could not save state: \(error)\n", stderr)
        }
    }

    private static func loadState(from url: URL) -> ChargeGuardState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ChargeGuardState.self, from: data) else {
            return ChargeGuardState()
        }
        return state
    }
}

func intEnvironment(_ name: String, default defaultValue: Int) -> Int {
    guard let raw = ProcessInfo.processInfo.environment[name], let value = Int(raw) else {
        return defaultValue
    }
    return value
}

@main
struct Glove80ChargeGuardMain {
    static func main() {
        let chargeLimit = intEnvironment("GLOVE80_CHARGE_LIMIT", default: 80)
        let resumeLevel = intEnvironment("GLOVE80_CHARGE_RESUME", default: 70)
        let pollSeconds = intEnvironment("GLOVE80_CHARGE_POLL_SECONDS", default: 60)

        guard (1...100).contains(chargeLimit) else {
            fatalError("GLOVE80_CHARGE_LIMIT must be between 1 and 100")
        }
        guard (0..<chargeLimit).contains(resumeLevel) else {
            fatalError("GLOVE80_CHARGE_RESUME must be below GLOVE80_CHARGE_LIMIT")
        }
        guard pollSeconds >= 15 else {
            fatalError("GLOVE80_CHARGE_POLL_SECONDS must be at least 15")
        }

        let arguments = Set(CommandLine.arguments.dropFirst())
        let mode: RunMode
        if arguments.contains("--setup-usb") {
            mode = .setupUSB
        } else if arguments.contains("--usb-status") {
            mode = .usbStatus
        } else if arguments.contains("--status") {
            mode = .status
        } else if arguments.contains("--full-charge") {
            mode = .enableFullCharge
        } else if arguments.contains("--cancel-full-charge") {
            mode = .disableFullCharge
        } else if arguments.contains("--once") {
            mode = .once
        } else {
            mode = .watch
        }

        let exitCode = Glove80ChargeGuard(
            chargeLimit: chargeLimit,
            resumeLevel: resumeLevel,
            pollInterval: TimeInterval(pollSeconds)
        ).run(mode: mode)
        exit(exitCode)
    }
}
