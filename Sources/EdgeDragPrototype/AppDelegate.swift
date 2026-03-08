import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let assistController = DragAssistController()
    private let statusWindowController = StatusWindowController()
    private var gestureSettings = GestureSettingsStore.load()
    private var isEnabled = false
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        assistController.updateGestureSettings(gestureSettings.dragAssistSettings)
        configureStatusWindow()
        configureStatusItem()
        refreshState(promptForTrust: true, revealIssues: true)
        startRefreshTimer()
    }

    private func configureStatusWindow() {
        statusWindowController.onRequestPermissions = { [weak self] in
            self?.refreshState(promptForTrust: true, revealIssues: true)
        }
        statusWindowController.onRefreshStatus = { [weak self] in
            self?.refreshState(promptForTrust: false, revealIssues: true)
        }
        statusWindowController.onOpenAccessibility = {
            PermissionController.openAccessibilitySettings()
        }
        statusWindowController.onOpenInputMonitoring = {
            PermissionController.openInputMonitoringSettings()
        }
        statusWindowController.onToggleSingleFinger = { [weak self] enabled in
            self?.setSingleFingerEnabled(enabled)
        }
        statusWindowController.onToggleThreeFinger = { [weak self] enabled in
            self?.setThreeFingerEnabled(enabled)
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "EdgeClutch"
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: isEnabled ? "停用" : "启用", action: #selector(toggleEnabled), keyEquivalent: "e"))
        menu.addItem(makeToggleMenuItem(title: "单指续拖", enabled: gestureSettings.singleFingerEnabled, action: #selector(toggleSingleFingerMenu)))
        menu.addItem(makeToggleMenuItem(title: "三指续拖", enabled: gestureSettings.threeFingerEnabled, action: #selector(toggleThreeFingerMenu)))
        menu.addItem(NSMenuItem(title: "重新检查权限", action: #selector(requestPermissions), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "显示状态窗口", action: #selector(showStatusWindow), keyEquivalent: "s"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        return menu
    }

    private func refreshMenu() {
        statusItem?.menu = buildMenu()
    }

    private func makeToggleMenuItem(title: String, enabled: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.state = enabled ? .on : .off
        item.target = self
        return item
    }

    private func startRefreshTimer() {
        guard refreshTimer == nil else {
            return
        }

        let timer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(handleRefreshTimer), userInfo: nil, repeats: true)
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func handleRefreshTimer() {
        refreshState(promptForTrust: false, revealIssues: false)
    }

    private func refreshState(promptForTrust: Bool, revealIssues: Bool) {
        let hasAccessibility = PermissionController.ensureAccessibilityTrust(prompt: promptForTrust)
        let hasInputMonitoring = PermissionController.ensureInputMonitoring(prompt: promptForTrust)
        let runtimeStatus: DragAssistController.RuntimeStatus

        if hasAccessibility && hasInputMonitoring {
            runtimeStatus = assistController.start()
            isEnabled = runtimeStatus.eventTapRunning && runtimeStatus.touchMonitorRunning
            statusItem?.button?.title = isEnabled ? "EdgeClutch 已开启" : "EdgeClutch 受限"
        } else {
            assistController.stop()
            runtimeStatus = assistController.runtimeStatus()
            isEnabled = false
            statusItem?.button?.title = "EdgeClutch 未开启"
        }

        updateStatusWindow(
            accessibilityGranted: hasAccessibility,
            inputMonitoringGranted: hasInputMonitoring,
            runtimeStatus: runtimeStatus
        )
        refreshMenu()

        if revealIssues && (!hasAccessibility || !hasInputMonitoring || !runtimeStatus.touchMonitorRunning || !runtimeStatus.eventTapRunning) {
            statusWindowController.show()
        }
    }

    private func updateStatusWindow(
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool,
        runtimeStatus: DragAssistController.RuntimeStatus
    ) {
        statusWindowController.update(
            snapshot: .init(
                accessibilityGranted: accessibilityGranted,
                inputMonitoringGranted: inputMonitoringGranted,
                eventTapRunning: runtimeStatus.eventTapRunning,
                touchMonitorRunning: runtimeStatus.touchMonitorRunning,
                executablePath: Bundle.main.bundleURL.path,
                version: AppMetadata.version,
                author: AppMetadata.author,
                singleFingerEnabled: gestureSettings.singleFingerEnabled,
                threeFingerEnabled: gestureSettings.threeFingerEnabled
            )
        )
    }

    private func applyGestureSettings() {
        GestureSettingsStore.save(gestureSettings)
        assistController.updateGestureSettings(gestureSettings.dragAssistSettings)
        updateStatusWindow(
            accessibilityGranted: PermissionController.ensureAccessibilityTrust(prompt: false),
            inputMonitoringGranted: PermissionController.ensureInputMonitoring(prompt: false),
            runtimeStatus: assistController.runtimeStatus()
        )
        refreshMenu()
    }

    private func setSingleFingerEnabled(_ enabled: Bool) {
        gestureSettings.singleFingerEnabled = enabled
        applyGestureSettings()
    }

    private func setThreeFingerEnabled(_ enabled: Bool) {
        gestureSettings.threeFingerEnabled = enabled
        applyGestureSettings()
    }

    @objc private func toggleEnabled() {
        if isEnabled {
            assistController.stop()
            isEnabled = false
            statusItem?.button?.title = "EdgeClutch 未开启"
            refreshMenu()
            return
        }

        refreshState(promptForTrust: true, revealIssues: true)
    }

    @objc private func requestPermissions() {
        refreshState(promptForTrust: true, revealIssues: true)
    }

    @objc private func showStatusWindow() {
        statusWindowController.show()
    }

    @objc private func toggleSingleFingerMenu() {
        setSingleFingerEnabled(!gestureSettings.singleFingerEnabled)
    }

    @objc private func toggleThreeFingerMenu() {
        setThreeFingerEnabled(!gestureSettings.threeFingerEnabled)
    }

    @objc private func quit() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        assistController.stop()
        NSApplication.shared.terminate(nil)
    }
}

@MainActor
enum PermissionController {
    static func ensureAccessibilityTrust(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func ensureInputMonitoring(prompt: Bool) -> Bool {
        guard #available(macOS 10.15, *) else {
            return true
        }

        let granted = CGPreflightListenEventAccess()
        if !granted && prompt {
            CGRequestListenEventAccess()
        }
        return granted
    }

    static func openAccessibilitySettings() {
        openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func openSettingsPane(_ value: String) {
        guard let url = URL(string: value) else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}

private enum AppMetadata {
    static let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.2"
    static let author = "Ao Chen"
}

private struct GestureSettings {
    var singleFingerEnabled: Bool
    var threeFingerEnabled: Bool

    var dragAssistSettings: DragAssistController.GestureSettings {
        .init(
            singleFingerEnabled: singleFingerEnabled,
            threeFingerEnabled: threeFingerEnabled
        )
    }
}

private enum GestureSettingsStore {
    private static let singleFingerKey = "gesture.singleFingerEnabled"
    private static let threeFingerKey = "gesture.threeFingerEnabled"

    static func load() -> GestureSettings {
        let defaults = UserDefaults.standard
        return GestureSettings(
            singleFingerEnabled: defaults.object(forKey: singleFingerKey) as? Bool ?? true,
            threeFingerEnabled: defaults.object(forKey: threeFingerKey) as? Bool ?? true
        )
    }

    static func save(_ settings: GestureSettings) {
        let defaults = UserDefaults.standard
        defaults.set(settings.singleFingerEnabled, forKey: singleFingerKey)
        defaults.set(settings.threeFingerEnabled, forKey: threeFingerKey)
    }
}
