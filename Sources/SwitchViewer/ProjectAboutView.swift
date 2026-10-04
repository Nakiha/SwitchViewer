import AppKit

/// Project links and attribution share the toolbar's expandable reading surface.
final class ProjectAboutView: NSStackView {
    private static let repositoryURL = URL(string: "https://github.com/Nakiha/SwitchViewer")!
    private static let authorURL = URL(string: "https://github.com/Nakiha")!
    private static let licenseURL = URL(string: "https://opensource.org/license/mit")!

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 14
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"
        let title = NSTextField(labelWithString: "SwitchViewer · \(version)")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        addArrangedSubview(title)
        addArrangedSubview(row("作者", link("Nakiha", action: #selector(openAuthor))))
        addArrangedSubview(row("代码仓库", link("github.com/Nakiha/SwitchViewer", action: #selector(openRepository))))
        addArrangedSubview(row("开源许可证", link("MIT License", action: #selector(openLicense))))
        let copyright = NSTextField(labelWithString: "Copyright © 2026 Nakiha")
        copyright.font = .systemFont(ofSize: 11)
        copyright.textColor = .secondaryLabelColor
        addArrangedSubview(copyright)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func row(_ title: String, _ button: NSButton) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let stack = NSStackView(views: [label, button])
        stack.spacing = 8
        return stack
    }

    private func link(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        if #available(macOS 26.0, *) { button.bezelStyle = .glass }
        return button
    }

    @objc private func openRepository() { NSWorkspace.shared.open(Self.repositoryURL) }
    @objc private func openAuthor() { NSWorkspace.shared.open(Self.authorURL) }
    @objc private func openLicense() {
        let url = Bundle.main.url(forResource: "LICENSE", withExtension: "txt") ?? Self.licenseURL
        NSWorkspace.shared.open(url)
    }
}
