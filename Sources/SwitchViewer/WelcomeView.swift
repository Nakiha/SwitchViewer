import AppKit

final class WelcomeView: NSView {
    var onChooseScreen: ((NSButton) -> Void)?
    var onChooseDevice: ((NSButton) -> Void)?

    init(frame frameRect: NSRect, message: String? = nil) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let symbol = NSImageView(image: NSImage(systemSymbolName: "display.2", accessibilityDescription: "SwitchViewer")!)
        symbol.contentTintColor = .controlAccentColor
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbol.widthAnchor.constraint(equalToConstant: 76).isActive = true
        symbol.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let title = NSTextField(labelWithString: "欢迎使用 SwitchViewer")
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: message ?? "选择画面来源，开始预览")
        subtitle.alignment = .center
        subtitle.widthAnchor.constraint(equalToConstant: 540).isActive = true
        subtitle.font = .systemFont(ofSize: 17)
        subtitle.textColor = .secondaryLabelColor

        let screen = NSButton(title: "选择屏幕或游戏窗口…", target: self, action: #selector(chooseScreen(_:)))
        screen.bezelStyle = .rounded
        screen.controlSize = .large
        screen.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        screen.imagePosition = .imageLeading
        let device = NSButton(title: "选择采集卡或摄像头…", target: self, action: #selector(chooseDevice(_:)))
        device.bezelStyle = .rounded
        device.controlSize = .large
        device.image = NSImage(systemSymbolName: "video", accessibilityDescription: nil)
        device.imagePosition = .imageLeading
        for button in [screen, device] {
            button.widthAnchor.constraint(equalToConstant: 320).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        let note = NSTextField(wrappingLabelWithString: "打开应用不会启用摄像头、麦克风或屏幕采集。\n只有选择具体来源后才会开始；所需权限会在使用时申请。")
        note.alignment = .center
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 13)
        note.widthAnchor.constraint(equalToConstant: 440).isActive = true

        let stack = NSStackView(views: [symbol, title, subtitle, screen, device, note])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.setCustomSpacing(30, after: subtitle)
        stack.setCustomSpacing(24, after: device)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func chooseScreen(_ sender: NSButton) { onChooseScreen?(sender) }
    @objc private func chooseDevice(_ sender: NSButton) { onChooseDevice?(sender) }
}
