import AppKit
import SwitchViewerInterpolation

/// Shared controls, independently persisted for capture and injected games.
final class InterpolationOptionsControl: NSStackView, NSTextFieldDelegate {
    let multiplier = NSPopUpButton()
    let limit = NSButton(checkboxWithTitle: "限制插帧延迟", target: nil, action: nil)
    let milliseconds = NSTextField(string: "60")
    var onChange: ((InterpolationOptions) -> Void)?

    init(identifier: String) {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        multiplier.identifier = NSUserInterfaceItemIdentifier(identifier + "-multiplier")
        multiplier.addItems(withTitles: InterpolationMultiplier.allCases.map(\.label))
        multiplier.target = self; multiplier.action = #selector(changed)
        multiplier.toolTip = "按所选倍率生成帧；算力不足或超过延迟预算时丢弃来不及显示的插值帧，倍率不会自动降低。"
        let factorRow = NSStackView(views: [NSTextField(labelWithString: "插帧倍数"), multiplier])
        factorRow.spacing = 8; factorRow.alignment = .centerY
        addArrangedSubview(factorRow)
        limit.identifier = NSUserInterfaceItemIdentifier(identifier + "-limit")
        limit.target = self; limit.action = #selector(changed)
        limit.toolTip = "限制相对关闭插帧时增加的缓冲等待。关闭限制沿用默认时序。系统、GPU 和显示器仍可能产生额外延迟。"
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 0
        formatter.minimum = 0; formatter.maximum = 250; formatter.allowsFloats = false
        milliseconds.formatter = formatter
        milliseconds.identifier = NSUserInterfaceItemIdentifier(identifier + "-milliseconds")
        milliseconds.target = self; milliseconds.action = #selector(changed)
        milliseconds.delegate = self
        milliseconds.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let budgetRow = NSStackView(views: [limit, milliseconds, NSTextField(labelWithString: "ms")])
        budgetRow.spacing = 6; budgetRow.alignment = .centerY
        addArrangedSubview(budgetRow)
        let help = NSTextField(wrappingLabelWithString: "预算不足时丢弃超时插值帧；0–250 ms。")
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor
        addArrangedSubview(help)
        update(.init())
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func update(_ options: InterpolationOptions) {
        multiplier.selectItem(at: InterpolationMultiplier.allCases.firstIndex(of: options.multiplier) ?? 0)
        limit.state = options.delayBudgetMilliseconds == nil ? .off : .on
        if let budget = options.delayBudgetMilliseconds, window?.firstResponder !== milliseconds.currentEditor() {
            milliseconds.integerValue = Int(budget)
        }
        milliseconds.isEnabled = limit.state == .on && limit.isEnabled
    }
    func setControlsEnabled(_ enabled: Bool) {
        multiplier.isEnabled = enabled; limit.isEnabled = enabled
        milliseconds.isEnabled = enabled && limit.state == .on
    }
    func controlTextDidEndEditing(_ notification: Notification) { changed() }
    @objc private func changed() {
        let index = multiplier.indexOfSelectedItem
        guard InterpolationMultiplier.allCases.indices.contains(index) else { return }
        milliseconds.isEnabled = limit.state == .on
        onChange?(InterpolationOptions(multiplier: InterpolationMultiplier.allCases[index],
            delayBudgetMilliseconds: limit.state == .on ? milliseconds.doubleValue : nil))
    }
}
