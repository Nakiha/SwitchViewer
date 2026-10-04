import AppKit

/// One native segmented control owns both the selection background and its
/// contrasting label colors. Avoid overriding the glass button's title palette.
final class GlassChoiceControl: NSStackView {
    private let segments = NSSegmentedControl()
    var allowsEmptySelection = false
    var onChange: ((Int) -> Void)?
    var selection = 0 {
        didSet { segments.selectedSegment = selection }
    }

    init(_ titles: [String], symbols: [String] = []) {
        super.init(frame: .zero)
        segments.trackingMode = .selectOne
        segments.segmentStyle = .rounded
        segments.segmentDistribution = .fit
        segments.font = .systemFont(ofSize: 12)
        if #available(macOS 27.0, *) { segments.role = .valueSelection }
        setChoices(titles, symbols: symbols)
        selection = 0
        segments.selectedSegment = selection
        segments.target = self
        segments.action = #selector(selectChoice(_:))
        addArrangedSubview(segments)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setChoices(_ titles: [String], symbols: [String] = []) {
        segments.segmentCount = titles.count
        for (index, title) in titles.enumerated() {
            segments.setLabel(title, forSegment: index)
            segments.setToolTip(title, forSegment: index)
            let image = symbols.indices.contains(index)
                ? NSImage(systemSymbolName: symbols[index], accessibilityDescription: title)?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) : nil
            segments.setImage(image, forSegment: index)
            segments.setImageScaling(.scaleProportionallyDown, forSegment: index)
        }
        selection = -1
    }

    @objc private func selectChoice(_ sender: NSSegmentedControl) {
        let clicked = sender.selectedSegment
        selection = allowsEmptySelection && selection == clicked ? -1 : clicked
        onChange?(selection)
    }
}
