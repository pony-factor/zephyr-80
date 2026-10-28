import AppKit
import CoreGraphics
import Foundation
import IOKit.hid
import IOKit.pwr_mgt

private let shutdownNotification = Notification.Name("io.github.JFWooten4.glove80-mac-screen-rgb-sync.shutdown")
private let displaySleepNotification = Notification.Name("io.github.JFWooten4.glove80-mac-screen-rgb-sync.display-sleep")
private let displayWakeNotification = Notification.Name("io.github.JFWooten4.glove80-mac-screen-rgb-sync.display-wake")
// IOMessage.h function-like macros are not imported by Swift.
private let canSystemSleep: UInt32 = 0xe0000270
private let systemWillSleepMessage: UInt32 = 0xe0000280
private let systemHasPoweredOn: UInt32 = 0xe0000300

private func systemPowerCallback(context: UnsafeMutableRawPointer?, service: io_service_t,
                                 message: UInt32, argument: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let controller = Unmanaged<ScreenRGBSync>.fromOpaque(context).takeUnretainedValue()
    controller.systemPowerChanged(message, notificationID: Int(bitPattern: argument))
}

// Kept independent of HID so wake transitions and retry behavior can be tested.
struct WakeBrightnessPolicy {
    private var awaitingWake = false
    private var restoreBrightness = false
    private var restoredDevices: Set<UInt64> = []

    mutating func displayDidSleep() {
        awaitingWake = true
        restoreBrightness = false
        restoredDevices.removeAll()
    }

    mutating func displayDidWake() {
        guard awaitingWake else { return }
        restoreBrightness = true
        awaitingWake = false
    }

    func shouldRestore(deviceID: UInt64) -> Bool {
        restoreBrightness && !restoredDevices.contains(deviceID)
    }

    mutating func didRestore(deviceID: UInt64) {
        restoredDevices.insert(deviceID)
    }
}

private let restoreBrightnessBit: UInt8 = 1 << 0
private let capsLockBit: UInt8 = 1 << 1
private let shutdownMarkerBit: UInt8 = 1 << 2
private let composeMarkerBit: UInt8 = 1 << 3
private let kanaAwakeBit: UInt8 = 1 << 4

private func matchedDeviceCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard result == kIOReturnSuccess, let context else {
        return
    }

    let controller = Unmanaged<ScreenRGBSync>.fromOpaque(context).takeUnretainedValue()
    controller.deviceDidConnect(device)
}

final class ScreenRGBSync {
    private var manager: IOHIDManager
    private var displayAwake = true
    private var brightnessPolicy = WakeBrightnessPolicy()
    private var hostShuttingDown = false
    private var wakeSyncGeneration = 0
    private var retrySequenceActive = false
    private var needsConnectionRefresh = false
    private var systemNotificationPort: IONotificationPortRef?
    private var systemNotifier: io_object_t = 0
    private var powerConnection: io_connect_t = 0
    private let wakeSyncRetryDelays: [TimeInterval] = [0, 0.25, 0.5, 1, 2, 4, 8, 12, 30, 60]

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func run() {
        // Workspace sleep/wake notifications require AppKit's application event loop.
        // Keep the helper invisible while it waits for events, with no polling timer.
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        if CommandLine.arguments.contains("--shutdown-only") {
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(announceShutdown),
                name: NSWorkspace.willPowerOffNotification, object: nil
            )
            application.run()
            return
        }

        if CommandLine.arguments.contains("--forward-only") {
            let center = NSWorkspace.shared.notificationCenter
            center.addObserver(self, selector: #selector(announceShutdown),
                               name: NSWorkspace.willPowerOffNotification, object: nil)
            center.addObserver(self, selector: #selector(announceDisplaySleep),
                               name: NSWorkspace.screensDidSleepNotification, object: nil)
            center.addObserver(self, selector: #selector(announceDisplayWake),
                               name: NSWorkspace.screensDidWakeNotification, object: nil)
            forwardDisplayState(CGDisplayIsAsleep(CGMainDisplayID()) == 0)
            application.run()
            return
        }

        guard openManager() else {
            exit(1)
        }

        displayAwake = CGDisplayIsAsleep(CGMainDisplayID()) == 0
        if !displayAwake { brightnessPolicy.displayDidSleep() }

        if CommandLine.arguments.contains("--system") {
            guard geteuid() == 0, observePower() else { exit(1) }
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(systemWillPowerOff),
                name: shutdownNotification, object: nil, suspensionBehavior: .deliverImmediately
            )
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(screensDidSleep),
                name: displaySleepNotification, object: nil, suspensionBehavior: .deliverImmediately
            )
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(screensDidWake),
                name: displayWakeNotification, object: nil, suspensionBehavior: .deliverImmediately
            )
            beginWakeSync(displayIsKnownAwake: displayAwake)
            application.run()
            return
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemWillPowerOff),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )

        // Login/startup can discover the keyboard before HID output is ready.
        // Recover initial failures just as we do after waking from sleep.
        beginWakeSync(displayIsKnownAwake: displayAwake)
        application.run()
    }

    @objc private func announceShutdown(_ notification: Notification) {
        DistributedNotificationCenter.default().postNotificationName(
            shutdownNotification, object: nil, userInfo: nil,
            options: [.deliverImmediately, .postToAllSessions]
        )
        // Allow the daemon to send the shutdown marker before transports stop.
        Thread.sleep(forTimeInterval: 1.75)
    }

    @objc private func announceDisplaySleep(_ notification: Notification) {
        forwardDisplayState(false)
    }

    @objc private func announceDisplayWake(_ notification: Notification) {
        forwardDisplayState(true)
    }

    private func forwardDisplayState(_ awake: Bool) {
        DistributedNotificationCenter.default().postNotificationName(
            awake ? displayWakeNotification : displaySleepNotification,
            object: nil, userInfo: nil, options: [.deliverImmediately, .postToAllSessions]
        )
        fputs("ScreenRGBSync: forwarded display \(awake ? "awake" : "asleep")\n", stderr)
    }

    private func observePower() -> Bool {
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerConnection = IORegisterForSystemPower(
            context, &systemNotificationPort, systemPowerCallback, &systemNotifier
        )
        guard powerConnection != 0, let systemNotificationPort else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(systemNotificationPort).takeUnretainedValue(), .defaultMode)
        fputs("ScreenRGBSync: system power observers ready\n", stderr)
        return true
    }

    fileprivate func systemPowerChanged(_ message: UInt32, notificationID: Int) {
        switch message {
        case canSystemSleep:
            IOAllowPowerChange(powerConnection, notificationID)
        case systemWillSleepMessage:
            turnOffRGBBeforeHostPowerChange()
            IOAllowPowerChange(powerConnection, notificationID)
        case systemHasPoweredOn:
            beginWakeSync(displayIsKnownAwake: displayAwake)
        default:
            break
        }
    }

    private func openManager() -> Bool {
        let matching: [String: Any] = [
            kIOHIDProductKey: "Glove80",
            kIOHIDDeviceUsagePageKey: Int(kHIDPage_GenericDesktop),
            kIOHIDDeviceUsageKey: Int(kHIDUsage_GD_Keyboard),
        ]

        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            matchedDeviceCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            fputs("ScreenRGBSync: could not open IOHIDManager (\(openResult))\n", stderr)
            if openResult == kIOReturnNotPermitted {
                fputs("ScreenRGBSync: enable ScreenRGBSync in System Settings > Privacy & Security > Input Monitoring, then restart the helper\n", stderr)
            }
            return false
        }

        return true
    }

    private func refreshConnection() {
        // USB/Bluetooth handles can survive sleep but reject output reports.
        // Recreate the manager so wake retries use newly opened device handles.
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(
            manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        needsConnectionRefresh = !openManager()
    }

    @objc private func screensDidSleep(_ notification: Notification) {
        wakeSyncGeneration += 1
        retrySequenceActive = false
        displayAwake = false
        brightnessPolicy.displayDidSleep()
        syncAll()
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        turnOffRGBBeforeHostPowerChange()
    }

    @objc private func screensDidWake(_ notification: Notification) {
        // This notification is authoritative even when CGDisplayIsAsleep still
        // reports the pre-wake state while the lock screen is coming up.
        beginWakeSync(displayIsKnownAwake: true)
    }

    @objc private func systemDidWake(_ notification: Notification) {
        // A system wake can be a dark/background wake. If the display has already
        // announced that it woke, preserve that authoritative state; otherwise
        // keep checking the display before lighting the keyboard.
        beginWakeSync(displayIsKnownAwake: displayAwake)
    }

    @objc private func systemWillPowerOff(_ notification: Notification) {
        hostShuttingDown = true
        turnOffRGBBeforeHostPowerChange()
    }

    private func turnOffRGBBeforeHostPowerChange() {
        // Apple-menu Sleep (or Shut Down) can suspend the HID transport before
        // the Glove80's asynchronous 1.5-second RGB fade finishes. Send the
        // off report synchronously, then keep the workspace notification
        // handler alive long enough for both halves to fade and cut LED power.
        // NSWorkspace allows willSleep observers up to 30 seconds to finish.
        wakeSyncGeneration += 1
        retrySequenceActive = false
        displayAwake = false
        brightnessPolicy.displayDidSleep()
        syncAll()
        Thread.sleep(forTimeInterval: 1.75)
    }

    private func beginWakeSync(displayIsKnownAwake: Bool) {
        wakeSyncGeneration += 1
        retrySequenceActive = true
        let generation = wakeSyncGeneration
        needsConnectionRefresh = true

        if displayIsKnownAwake {
            displayAwake = true
            brightnessPolicy.displayDidWake()
        }

        for delay in wakeSyncRetryDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard
                    let self,
                    self.wakeSyncGeneration == generation
                else {
                    return
                }

                // Display-wake notifications are authoritative. CGDisplayIsAsleep can
                // briefly lag while the lock screen appears, so only re-query it for
                // dark/background system wakes.
                if !displayIsKnownAwake {
                    self.displayAwake = CGDisplayIsAsleep(CGMainDisplayID()) == 0
                    if self.displayAwake { self.brightnessPolicy.displayDidWake() }
                }
                if self.needsConnectionRefresh {
                    self.refreshConnection()
                }
                self.syncAll()
                if delay == self.wakeSyncRetryDelays.last {
                    self.retrySequenceActive = false
                }
            }
        }
    }

    fileprivate func deviceDidConnect(_ device: IOHIDDevice) {
        guard isGlove80(device) else { return }
        sync(device: device)
        // A device can connect long after login. Start a bounded recovery series
        // on failure, but do not restart it for callbacks caused by reopening HID.
        if needsConnectionRefresh && !retrySequenceActive {
            beginWakeSync(displayIsKnownAwake: displayAwake)
        }
    }

    fileprivate func sync(device: IOHIDDevice) {
        guard isGlove80(device) else {
            return
        }

        // Registry IDs survive manager refreshes, so successful retries do not
        // reset brightness again after the user changes brightness.
        var deviceID: UInt64 = 0
        let identityResult = IORegistryEntryGetRegistryEntryID(
            IOHIDDeviceGetService(device), &deviceID
        )
        let restoreBrightness = displayAwake && identityResult == KERN_SUCCESS &&
            brightnessPolicy.shouldRestore(deviceID: deviceID)
        var leds = composeMarkerBit
        if restoreBrightness { leds |= restoreBrightnessBit }
        // Arm the firmware's pre-login fallback only for shutdown/restart.
        // Display/system sleep must keep RGB off through background reconnects.
        if hostShuttingDown {
            leds |= shutdownMarkerBit
        }
        if displayAwake {
            leds |= kanaAwakeBit
        }

        if CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift) {
            leds |= capsLockBit
        }

        // USB includes a report-ID prefix; BLE can expose an unnumbered LED report.
        // Use the actual descriptor instead of assuming every transport has ID 1.
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement],
              let marker = elements.first(where: {
                  IOHIDElementGetType($0) == kIOHIDElementTypeOutput &&
                  IOHIDElementGetUsagePage($0) == UInt32(kHIDPage_LEDs) &&
                  IOHIDElementGetUsage($0) == 4 // Compose
              }) else {
            fputs("ScreenRGBSync: Glove80 has no Compose LED output; flash screen-sync firmware\n", stderr)
            return
        }
        let reportID = CFIndex(IOHIDElementGetReportID(marker))
        let report: [UInt8] = reportID == 0 ? [leds] : [UInt8(reportID), leds]
        let result = report.withUnsafeBufferPointer { bytes in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, reportID,
                                 bytes.baseAddress!, bytes.count)
        }

        if result != kIOReturnSuccess {
            needsConnectionRefresh = true
            fputs("ScreenRGBSync: failed to send display state to Glove80 (\(result))\n", stderr)
            // A stale post-sleep handle can also return NotPermitted. Only
            // suggest a permission change when macOS actually denies access.
            if result == kIOReturnNotPermitted &&
                IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeDenied {
                fputs("ScreenRGBSync: enable ScreenRGBSync in System Settings > Privacy & Security > Input Monitoring, then restart the helper\n", stderr)
            }
        } else {
            if restoreBrightness {
                brightnessPolicy.didRestore(deviceID: deviceID)
                fputs("ScreenRGBSync: requested full RGB brightness after sleep\n", stderr)
            }
            fputs("ScreenRGBSync: Glove80 RGB \(displayAwake ? "awake" : "asleep") report sent\n", stderr)
        }
    }

    private func syncAll() {
        guard let devices = IOHIDManagerCopyDevices(manager) else {
            return
        }

        for case let device as IOHIDDevice in devices as NSSet {
            sync(device: device)
        }
    }

    private func isGlove80(_ device: IOHIDDevice) -> Bool {
        guard
            let property = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString),
            let product = property as? String
        else {
            return false
        }

        return product.localizedCaseInsensitiveContains("Glove80")
    }
}

let sync = ScreenRGBSync()
sync.run()
