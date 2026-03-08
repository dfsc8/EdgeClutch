import AppKit

@MainActor
final class StatusWindowController: NSWindowController {
    struct Snapshot {
        let accessibilityGranted: Bool
        let inputMonitoringGranted: Bool
        let eventTapRunning: Bool
        let touchMonitorRunning: Bool
        let executablePath: String
        let version: String
        let author: String
        let singleFingerEnabled: Bool
        let threeFingerEnabled: Bool
    }

    var onRequestPermissions: (() -> Void)?
    var onOpenAccessibility: (() -> Void)?
    var onOpenInputMonitoring: (() -> Void)?
    var onRefreshStatus: (() -> Void)?
    var onToggleSingleFinger: ((Bool) -> Void)?
    var onToggleThreeFinger: ((Bool) -> Void)?

    private let descriptionLabel = NSTextField(labelWithString: "EdgeClutch 会作为菜单栏应用运行。如果拖动到触控板边缘后没有继续移动，请检查下面的权限和运行状态。")
    private let versionLabel = NSTextField(labelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
    private let executablePathLabel = NSTextField(labelWithString: "")
    private let accessibilityLabel = NSTextField(labelWithString: "")
    private let inputMonitoringLabel = NSTextField(labelWithString: "")
    private let eventTapLabel = NSTextField(labelWithString: "")
    private let touchMonitorLabel = NSTextField(labelWithString: "")
    private let singleFingerCheckbox = NSButton(checkboxWithTitle: "启用单指续拖", target: nil, action: nil)
    private let threeFingerCheckbox = NSButton(checkboxWithTitle: "启用三指续拖", target: nil, action: nil)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "EdgeClutch 状态"
        window.center()
        super.init(window: window)
        configureWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(snapshot: Snapshot) {
        versionLabel.stringValue = "版本号：" + snapshot.version
        authorLabel.stringValue = "作者：" + snapshot.author
        executablePathLabel.stringValue = "应用路径：" + snapshot.executablePath
        accessibilityLabel.stringValue = "辅助功能：" + authorizationText(snapshot.accessibilityGranted)
        inputMonitoringLabel.stringValue = "输入监控：" + authorizationText(snapshot.inputMonitoringGranted)
        eventTapLabel.stringValue = "事件监听：" + runtimeText(snapshot.eventTapRunning)
        touchMonitorLabel.stringValue = "触控板监听：" + runtimeText(snapshot.touchMonitorRunning)
        singleFingerCheckbox.state = snapshot.singleFingerEnabled ? .on : .off
        threeFingerCheckbox.state = snapshot.threeFingerEnabled ? .on : .off
    }

    func show() {
        guard let window else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func configureWindow() {
        guard let contentView = window?.contentView else {
            return
        }

        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.maximumNumberOfLines = 3
        executablePathLabel.lineBreakMode = .byTruncatingMiddle
        singleFingerCheckbox.target = self
        singleFingerCheckbox.action = #selector(toggleSingleFinger)
        threeFingerCheckbox.target = self
        threeFingerCheckbox.action = #selector(toggleThreeFinger)

        let gestureStack = NSStackView(views: [singleFingerCheckbox, threeFingerCheckbox])
        gestureStack.orientation = .horizontal
        gestureStack.alignment = .centerY
        gestureStack.spacing = 16
        gestureStack.distribution = .fillProportionally

        let requestButton = NSButton(title: "重新检查权限", target: self, action: #selector(requestPermissions))
        let refreshButton = NSButton(title: "刷新状态", target: self, action: #selector(refreshStatus))
        let accessibilityButton = NSButton(title: "打开辅助功能", target: self, action: #selector(openAccessibility))
        let inputMonitoringButton = NSButton(title: "打开输入监控", target: self, action: #selector(openInputMonitoring))

        let buttonStack = NSStackView(views: [requestButton, refreshButton, accessibilityButton, inputMonitoringButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 10
        buttonStack.distribution = .fillEqually

        let stack = NSStackView(views: [
            descriptionLabel,
            versionLabel,
            authorLabel,
            gestureStack,
            executablePathLabel,
            accessibilityLabel,
            inputMonitoringLabel,
            eventTapLabel,
            touchMonitorLabel,
            buttonStack,
        ])

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
        ])
    }

    @objc private func requestPermissions() {
        onRequestPermissions?()
    }

    @objc private func refreshStatus() {
        onRefreshStatus?()
    }

    @objc private func openAccessibility() {
        onOpenAccessibility?()
    }

    @objc private func openInputMonitoring() {
        onOpenInputMonitoring?()
    }

    @objc private func toggleSingleFinger() {
        onToggleSingleFinger?(singleFingerCheckbox.state == .on)
    }

    @objc private func toggleThreeFinger() {
        onToggleThreeFinger?(threeFingerCheckbox.state == .on)
    }

    private func authorizationText(_ enabled: Bool) -> String {
        enabled ? "已授权" : "未授权"
    }

    private func runtimeText(_ enabled: Bool) -> String {
        enabled ? "运行中" : "未运行"
    }
}
