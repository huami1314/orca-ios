import UIKit

/// Text laid out and drawn the way React Native's Fabric does it on iOS (RCTTextLayoutManager): TextKit 1, no font
/// leading, no line fragment padding, and a lineHeight centred with RCTApplyBaselineOffset. UILabel's own layout
/// differs in CJK punctuation widths and line heights, so this keeps UILabel only for Auto Layout and accessibility.
final class TextLabel: UILabel {
  var lineHeight: CGFloat? { didSet { restyle() } }
  var letterSpacing: CGFloat = 0 { didSet { restyle() } }
  private var raw: String?
  private var configuredTextColor: UIColor = .label
  private var isApplyingAttributedText = false
  private var cached: (width: CGFloat, lines: Int, text: NSAttributedString, layout: TextLayout)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    // Colours are resolved into the text, so a change of appearance redraws it. The app-switcher snapshot
    // flips the appearance and back while backgrounded; the legacy callback can miss the way back.
    registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitActiveAppearance.self]) { (label: TextLabel, _) in
      label.restyle()
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  convenience init(
    _ text: String? = nil, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = Palette.textPrimary,
    lineHeight: CGFloat? = nil, letterSpacing: CGFloat = 0, alignment: NSTextAlignment = .natural, lines: Int = 1,
    tabular: Bool = false
  ) {
    self.init(frame: .zero)
    var font = UIFont.systemFont(ofSize: size, weight: weight)
    if tabular {
      font = UIFont(
        descriptor: font.fontDescriptor.addingAttributes([
          .featureSettings: [
            [UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
             UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector]
          ]
        ]), size: size)
    }
    self.font = font
    textColor = color
    textAlignment = alignment
    numberOfLines = lines
    self.lineHeight = lineHeight
    self.letterSpacing = letterSpacing
    translatesAutoresizingMaskIntoConstraints = false
    self.text = text
  }

  override var text: String? {
    get { raw }
    set {
      raw = newValue
      runs = nil
      restyle()
    }
  }

  /// Fully styled text (Markdown); its own attributes win over the label's.
  var styledText: NSAttributedString? {
    didSet {
      raw = styledText?.string
      applyAttributedText(styledText)
    }
  }

  /// Text in coloured pieces, as nested RN <Text> elements colour parts of one line.
  var runs: [(String, UIColor)]? {
    didSet {
      if let runs {
        raw = runs.map(\.0).joined()
        restyle()
      }
    }
  }

  override var textColor: UIColor! {
    didSet {
      guard !isApplyingAttributedText else { return }
      configuredTextColor = textColor ?? .label
      if raw != nil { restyle() }
    }
  }

  override var font: UIFont! {
    didSet { if !isApplyingAttributedText, raw != nil { restyle() } }
  }

  private func restyle() {
    if styledText != nil { return }
    guard let raw, let font else {
      applyAttributedText(nil)
      return
    }
    // UILabel mirrors the first run into textColor. Resolve from the colour supplied by the caller.
    var attributes: [NSAttributedString.Key: Any] = [
      .font: font, .foregroundColor: configuredTextColor.resolvedColor(with: traitCollection),
    ]
    if letterSpacing != 0 { attributes[.kern] = letterSpacing }
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = textAlignment
    if let lineHeight {
      paragraph.minimumLineHeight = lineHeight
      paragraph.maximumLineHeight = lineHeight
      if lineHeight > font.lineHeight {
        attributes[.baselineOffset] = (lineHeight - font.lineHeight) / 2
      }
    }
    attributes[.paragraphStyle] = paragraph
    if let runs {
      let text = NSMutableAttributedString()
      for (piece, color) in runs {
        var pieceAttributes = attributes
        pieceAttributes[.foregroundColor] = color.resolvedColor(with: traitCollection)
        text.append(NSAttributedString(string: piece, attributes: pieceAttributes))
      }
      applyAttributedText(text)
    } else {
      applyAttributedText(NSAttributedString(string: raw, attributes: attributes))
    }
  }

  private func applyAttributedText(_ value: NSAttributedString?) {
    isApplyingAttributedText = true
    attributedText = value
    isApplyingAttributedText = false
    cached = nil
    accessibilityLabel = raw
    invalidateIntrinsicContentSize()
    setNeedsDisplay()
  }

  private func layout(width: CGFloat, lines: Int) -> TextLayout? {
    guard let text = attributedText, text.length > 0 else { return nil }
    if let cached, cached.width == width, cached.lines == lines, cached.text == text { return cached.layout }
    let layout = TextLayout(text: text, width: width, lines: lines)
    cached = (width, lines, text, layout)
    return layout
  }

  override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
    // Unbounded measuring passes lay out on one long line; 100 000 pt stands in for "no limit".
    let width = bounds.width.isFinite && bounds.width > 0 ? min(bounds.width, 100_000) : 100_000
    guard let layout = layout(width: width, lines: numberOfLines) else {
      return CGRect(origin: bounds.origin, size: .zero)
    }
    let used = layout.usedRect
    guard used.width.isFinite, used.height.isFinite else { return CGRect(origin: bounds.origin, size: .zero) }
    // A centred or trailing line sits away from x 0 in a wide container; its width is what the label needs.
    let fitted = width >= 100_000 ? used.width : min(width, used.maxX)
    return CGRect(origin: bounds.origin, size: CGSize(width: ceil(fitted), height: ceil(used.height)))
  }

  /// The attribute under a point in this label, for tappable links and paths.
  func attribute(_ key: NSAttributedString.Key, at point: CGPoint) -> Any? {
    guard let layout = layout(width: bounds.width, lines: numberOfLines), let text = attributedText else { return nil }
    let top = max(0, (bounds.height - ceil(layout.usedRect.height)) / 2)
    guard let index = layout.characterIndex(at: CGPoint(x: point.x, y: point.y - top)), index < text.length else { return nil }
    return text.attribute(key, at: index, effectiveRange: nil)
  }

  override func drawText(in rect: CGRect) {
    guard let layout = layout(width: bounds.width, lines: numberOfLines) else { return }
    // UILabel centres its text vertically; the label is as tall as its text, so this only matters when stretched.
    let top = max(0, (bounds.height - ceil(layout.usedRect.height)) / 2)
    layout.draw(at: CGPoint(x: 0, y: top))
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    restyle()
  }
}

extension NSAttributedString.Key {
  /// Paints a rounded chip behind a run (inline code). The value is the chip's fill colour.
  static let chipBackground = NSAttributedString.Key("orca.chipBackground")
}

/// Draws chip backgrounds as rounded rects, one per line fragment the run spans.
private final class ChipLayoutManager: NSLayoutManager {
  override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
    super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    guard let storage = textStorage, let container = textContainers.first,
      let context = UIGraphicsGetCurrentContext()
    else { return }
    let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
    storage.enumerateAttribute(.chipBackground, in: characters) { value, range, _ in
      guard let color = value as? UIColor else { return }
      let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      enumerateEnclosingRects(
        forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
      ) { rect, _ in
        // Hug the glyphs, not the whole line: a chip is the code font's height plus 2 pt each way.
        let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
        let height = (font?.lineHeight ?? rect.height) + 2
        // The run already carries its padding (thin spaces); trim the trailing kern so the fill ends at the text.
        let chip = CGRect(x: rect.minX, y: rect.midY - height / 2, width: max(0, rect.width - 2), height: height)
          .offsetBy(dx: origin.x, dy: origin.y)
        context.setFillColor(color.cgColor)
        context.addPath(UIBezierPath(roundedRect: chip, cornerRadius: Radius.mark).cgPath)
        context.fillPath()
      }
    }
  }
}

/// One TextKit 1 layout, configured as React Native configures it.
private final class TextLayout {
  private let storage: NSTextStorage
  private let manager: NSLayoutManager = ChipLayoutManager()
  private let container: NSTextContainer

  init(text: NSAttributedString, width: CGFloat, lines: Int) {
    storage = NSTextStorage(attributedString: text)
    container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    container.maximumNumberOfLines = lines
    container.lineBreakMode = lines > 0 ? .byTruncatingTail : .byClipping
    manager.usesFontLeading = false
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    manager.ensureLayout(for: container)
  }

  var usedRect: CGRect { manager.usedRect(for: container) }

  /// The character drawn at a point, or nil past the text's edges.
  func characterIndex(at point: CGPoint) -> Int? {
    var fraction: CGFloat = 0
    let glyph = manager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
    let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
    guard rect.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
    return manager.characterIndexForGlyph(at: glyph)
  }

  func draw(at origin: CGPoint) {
    let range = manager.glyphRange(for: container)
    manager.drawBackground(forGlyphRange: range, at: origin)
    manager.drawGlyphs(forGlyphRange: range, at: origin)
  }
}

/// A control with the official press look: a callback per pressed state, so each component draws its own.
class PressableControl: UIControl {
  var onPress: (() -> Void)?
  var onPressedChange: ((Bool) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    addAction(UIAction { [weak self] _ in self?.onPress?() }, for: .touchUpInside)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isHighlighted: Bool {
    didSet {
      guard oldValue != isHighlighted else { return }
      onPressedChange?(isHighlighted)
    }
  }

  override var isEnabled: Bool {
    didSet { alpha = isEnabled ? 1 : Feedback.disabledOpacity }
  }
}

extension UIView {
  /// Animates like the official Reanimated press transitions: 90 ms in, 160 ms out, ease-out.
  func animatePress(_ pressed: Bool, scale: CGFloat? = nil, opacity: CGFloat? = nil) {
    UIView.animate(
      withDuration: pressed ? 0.09 : 0.16, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
    ) {
      if let scale { self.transform = pressed ? CGAffineTransform(scaleX: scale, y: scale) : .identity }
      if let opacity { self.alpha = pressed ? opacity : 1 }
    }
  }

  func pin(to other: UIView, insets: UIEdgeInsets = .zero) {
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
      trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
      topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
      bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
    ])
  }
}

/// A hairline, React Native's `StyleSheet.hairlineWidth`.
final class Hairline: UIView {
  init(color: UIColor = Palette.borderSubtle) {
    super.init(frame: .zero)
    backgroundColor = color
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The Orca orca mark (components/icons/OrcaLogo.tsx), `size` tall.
final class OrcaLogoView: UIView {
  private let shape = CAShapeLayer()
  private let color: UIColor
  private static let aspect: CGFloat = 318.6 / 202.67
  private static let path: CGPath = {
    let path = CGMutablePath()
    SVGPathParser.append(
      "m 177.81311,248.33334 c 23.82304,-41.29793 40.54045,-66.84626 49.51207,-75.66667 6.81685,-6.70196 10.07373,-8.7374 20.07265,-12.54475 34.57822,-13.16655 61.04674,-26.78733 72.37222,-37.24295 9.62924,-8.88966 9.34286,-9.01142 -23.43671,-9.964 -35.71756,-1.03796 -43.72989,0.42119 -62.17546,11.323 -16.72118,9.88265 -34.20103,30.11225 -42.74704,49.47157 -2.57353,5.82985 -14.81294,44.3056 -27.96399,87.90747 -2.86036,9.48343 -3.02466,11.71633 -0.86213,11.71633 0.44382,0 7.29659,-11.25 15.22839,-25 z m -65.14644,-8.32267 C 120,239.3326 130.5,237.50979 136,235.95998 c 5.5,-1.5498 12.25,-3.13783 15,-3.52895 2.75,-0.39111 5,-0.95485 5,-1.25275 0,-0.29789 2.15135,-7.58487 4.78078,-16.19328 8.49209,-27.80201 12.21334,-40.41629 21.13747,-71.65166 4.81891,-16.86667 11.23502,-39.185 14.25802,-49.596301 5.12803,-17.66103 5.74763,-23.07037 2.64253,-23.07037 -1.84887,0 -4.07048,6.908293 -16.72243,52.000001 -21.78975,77.65896 -20.80806,74.74393 -26.84794,79.72251 -7.5925,6.25838 -25.03916,14.82524 -36.10856,17.73044 -17.0947,4.48656 -33.410599,3.86724 -53.116765,-2.01622 -18.569242,-5.54403 -23.142662,-5.80284 -33.639754,-1.9037 -5.875424,2.18242 -9.864152,5.04363 -16.716684,11.99127 -4.95,5.0187 -9.0000001,10.02884 -9.0000001,11.13364 0,1.75174 5.9276921,2.00299 46.3333351,1.96383 25.483334,-0.0247 52.333338,-0.59969 59.666668,-1.27777 z M 252.69513,104.63708 c 12.18267,-3.48651 15.77304,-7.895503 9.63821,-11.835773 -10.19296,-6.546726 -36.19849,-1.77301 -41.19436,7.561863 -1.2556,2.3461 -0.98698,3.2037 1.68353,5.375 2.69471,2.19098 4.59991,2.47691 12.53928,1.88189 5.14899,-0.3859 12.94899,-1.72824 17.33334,-2.98298 z",
      to: path)
    return path
  }()

  init(size: CGFloat, color: UIColor = Palette.textPrimary) {
    self.color = color
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: size),
      widthAnchor.constraint(equalToConstant: size * Self.aspect),
    ])
    layer.addSublayer(shape)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    // viewBox 0 0 318.6 202.67, content translated by (-6.67, -70.67).
    let scale = bounds.height / 202.66667
    var transform = CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: -6.6666669, y: -70.666669)
    shape.frame = bounds
    shape.path = Self.path.copy(using: &transform)
    shape.fillColor = color.resolvedColor(with: traitCollection).cgColor
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    setNeedsLayout()
  }
}

/// One muted line in a list, such as an empty section's note; only as tall as its text.
struct NoteRowConfiguration: UIContentConfiguration {
  var text: String
  var insets: NSDirectionalEdgeInsets

  func makeContentView() -> UIView & UIContentView { NoteRowView(configuration: self) }
  func updated(for state: UIConfigurationState) -> NoteRowConfiguration { self }
}

private final class NoteRowView: UIView, UIContentView {
  private let label = TextLabel(size: 14, color: Palette.textSecondary, lines: 0)
  private var constraintsForInsets: [NSLayoutConstraint] = []
  var configuration: UIContentConfiguration { didSet { apply() } }

  init(configuration: NoteRowConfiguration) {
    self.configuration = configuration
    super.init(frame: .zero)
    addSubview(label)
    apply()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func apply() {
    guard let configuration = configuration as? NoteRowConfiguration else { return }
    label.text = configuration.text
    NSLayoutConstraint.deactivate(constraintsForInsets)
    let insets = configuration.insets
    constraintsForInsets = [
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.leading),
      label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -insets.trailing),
      label.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
    ]
    NSLayoutConstraint.activate(constraintsForInsets)
  }
}
