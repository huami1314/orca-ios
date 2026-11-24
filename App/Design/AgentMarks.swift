import UIKit

// Agent marks from the official app (components/icons/AgentIcons.tsx), filled in a 24×24 box.
enum AgentMark {
  static let claude = FilledIcon(d: "M4.709 15.955l4.72-2.647.08-.23-.08-.128H9.2l-.79-.048-2.698-.073-2.339-.097-2.266-.122-.571-.121L0 11.784l.055-.352.48-.321.686.06 1.52.103 2.278.158 1.652.097 2.449.255h.389l.055-.157-.134-.098-.103-.097-2.358-1.596-2.552-1.688-1.336-.972-.724-.491-.364-.462-.158-1.008.656-.722.881.06.225.061.893.686 1.908 1.476 2.491 1.833.365.304.145-.103.019-.073-.164-.274-1.355-2.446-1.446-2.49-.644-1.032-.17-.619a2.97 2.97 0 01-.104-.729L6.283.134 6.696 0l.996.134.42.364.62 1.414 1.002 2.229 1.555 3.03.456.898.243.832.091.255h.158V9.01l.128-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.584.28.48.685-.067.444-.286 1.851-.559 2.903-.364 1.942h.212l.243-.242.985-1.306 1.652-2.064.73-.82.85-.904.547-.431h1.033l.76 1.129-.34 1.166-1.064 1.347-.881 1.142-1.264 1.7-.79 1.36.073.11.188-.02 2.856-.606 1.543-.28 1.841-.315.833.388.091.395-.328.807-1.969.486-2.309.462-3.439.813-.042.03.049.061 1.549.146.662.036h1.622l3.02.225.79.522.474.638-.079.485-1.215.62-1.64-.389-3.829-.91-1.312-.329h-.182v.11l1.093 1.068 2.006 1.81 2.509 2.33.127.578-.322.455-.34-.049-2.205-1.657-.851-.747-1.926-1.62h-.128v.17l.444.649 2.345 3.521.122 1.08-.17.353-.608.213-.668-.122-1.374-1.925-1.415-2.167-1.143-1.943-.14.08-.674 7.254-.316.37-.729.28-.607-.461-.322-.747.322-1.476.389-1.924.315-1.53.286-1.9.17-.632-.012-.042-.14.018-1.434 1.967-2.18 2.945-1.726 1.845-.414.164-.717-.37.067-.662.401-.589 2.388-3.036 1.44-1.882.93-1.086-.006-.158h-.055L4.132 18.56l-1.13.146-.487-.456.061-.746.231-.243 1.908-1.312-.006.006z", color: UIColor(hex: 0xD97757), evenOdd: false)
  /// Codex: the OpenAI mark in the primary text colour.
  static let codex = FilledIcon(d: "M9.205 8.658v-2.26c0-.19.072-.333.238-.428l4.543-2.616c.619-.357 1.356-.523 2.117-.523 2.854 0 4.662 2.212 4.662 4.566 0 .167 0 .357-.024.547l-4.71-2.759a.797.797 0 00-.856 0l-5.97 3.473zm10.609 8.8V12.06c0-.333-.143-.57-.429-.737l-5.97-3.473 1.95-1.118a.433.433 0 01.476 0l4.543 2.617c1.309.76 2.189 2.378 2.189 3.948 0 1.808-1.07 3.473-2.76 4.163zM7.802 12.703l-1.95-1.142c-.167-.095-.239-.238-.239-.428V5.899c0-2.545 1.95-4.472 4.591-4.472 1 0 1.927.333 2.712.928L8.23 5.067c-.285.166-.428.404-.428.737v6.898zM12 15.128l-2.795-1.57v-3.33L12 8.658l2.795 1.57v3.33L12 15.128zm1.796 7.23c-1 0-1.927-.332-2.712-.927l4.686-2.712c.285-.166.428-.404.428-.737v-6.898l1.974 1.142c.167.095.238.238.238.428v5.233c0 2.545-1.974 4.472-4.614 4.472zm-5.637-5.303l-4.544-2.617c-1.308-.761-2.188-2.378-2.188-3.948A4.482 4.482 0 014.21 6.327v5.423c0 .333.143.571.428.738l5.947 3.449-1.95 1.118a.432.432 0 01-.476 0zm-.262 3.9c-2.688 0-4.662-2.021-4.662-4.519 0-.19.024-.38.047-.57l4.686 2.71c.286.167.571.167.856 0l5.97-3.448v2.26c0 .19-.07.333-.237.428l-4.543 2.616c-.619.357-1.356.523-2.117.523zm5.899 2.83a5.947 5.947 0 005.827-4.756C22.287 18.339 24 15.84 24 13.296c0-1.665-.713-3.282-1.998-4.448.119-.5.19-.999.19-1.498 0-3.401-2.759-5.947-5.946-5.947-.642 0-1.26.095-1.88.31A5.962 5.962 0 0010.205 0a5.947 5.947 0 00-5.827 4.757C1.713 5.447 0 7.945 0 10.49c0 1.666.713 3.283 1.998 4.448-.119.5-.19 1-.19 1.499 0 3.401 2.759 5.946 5.946 5.946.642 0 1.26-.095 1.88-.309a5.96 5.96 0 004.162 1.713z", color: nil, evenOdd: true)

  /// The mark for an agent id, or nil for agents drawn as a terminal glyph.
  static func icon(for agent: String?) -> FilledIcon? {
    switch agent {
    case "claude", "claude-agent-teams": claude
    case "codex": codex
    default: nil
    }
  }

  static func overlayType(for agent: String?) -> String? {
    guard let agent = agent?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
    let type: String = switch agent {
    case "claude-agent-teams": "claude"
    case "opencode2": "opencode"
    default: agent
    }
    return icon(for: type) != nil || UIImage(named: "AgentLogos/\(type)") != nil ? type : nil
  }

  enum OverlayBackdrop {
    case transparent
    case lightOpaque
    case darkOpaque
  }

  private static let lightOpaqueTypes: Set<String> = [
    "ante", "aug", "autohand", "codebuddy", "copilot", "crush", "grok", "prime-agent",
  ]
  private static let darkOpaqueTypes: Set<String> = [
    "command-code", "droid", "hermes", "kilo", "kiro", "mimo-code", "opencode", "trae",
  ]

  static func overlayBackdrop(for type: String?) -> OverlayBackdrop {
    guard let type else { return .transparent }
    if lightOpaqueTypes.contains(type) { return .lightOpaque }
    if darkOpaqueTypes.contains(type) { return .darkOpaque }
    return .transparent
  }

  private struct OverlayCacheKey: Hashable {
    let type: String?
    let sizeTenths: Int
  }

  private static let overlayCacheLock = NSLock()
  private nonisolated(unsafe) static var overlayCache: [OverlayCacheKey: UIImage] = [:]

  /// The overlay is always dark, even when the phone is in light appearance.
  static func overlayImage(for type: String?, size: CGFloat) -> UIImage {
    let key = OverlayCacheKey(type: type, sizeTenths: Int((size * 10).rounded()))
    overlayCacheLock.lock()
    if let cached = overlayCache[key] {
      overlayCacheLock.unlock()
      return cached
    }
    overlayCacheLock.unlock()

    let image: UIImage
    if let mark = icon(for: type) {
      let rendered = mark.image(size: size, scale: 3)
      image = mark.color == nil ? rendered.withTintColor(.white, renderingMode: .alwaysOriginal) : rendered
    } else if let type, let asset = UIImage(named: "AgentLogos/\(type)") {
      image = asset
    } else {
      image = Lucide.bot.image(size: size).withTintColor(.white, renderingMode: .alwaysOriginal)
    }

    overlayCacheLock.lock()
    if overlayCache.count >= 128 { overlayCache.removeAll(keepingCapacity: true) }
    overlayCache[key] = image
    overlayCacheLock.unlock()
    return image
  }
}

struct FilledIcon {
  let d: String
  /// Nil draws in the primary text colour.
  let color: UIColor?
  let evenOdd: Bool
  let path: CGPath

  init(d: String, color: UIColor?, evenOdd: Bool) {
    self.d = d
    self.color = color
    self.evenOdd = evenOdd
    let parsed = CGMutablePath()
    SVGPathParser.append(d, to: parsed)
    self.path = parsed.copy() ?? parsed
  }

  /// The mark as an image, for menus. A coloured mark keeps its colour; a plain one follows the tint.
  func image(size: CGFloat, scale: CGFloat? = nil) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    if let scale { format.scale = scale }
    let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
      let factor = size / 24
      context.cgContext.scaleBy(x: factor, y: factor)
      context.cgContext.addPath(path)
      context.cgContext.setFillColor((color ?? .black).cgColor)
      context.cgContext.fillPath(using: evenOdd ? .evenOdd : .winding)
    }
    return image.withRenderingMode(color == nil ? .alwaysTemplate : .alwaysOriginal)
  }
}

/// Draws a filled 24×24 mark at any size.
final class FilledIconView: UIView {
  private let shape = CAShapeLayer()
  var icon: FilledIcon? { didSet { setNeedsLayout() } }

  init(size: CGFloat) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    layer.addSublayer(shape)
    NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size)])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let icon else {
      shape.path = nil
      return
    }
    var transform = CGAffineTransform(scaleX: bounds.width / 24, y: bounds.height / 24)
    shape.frame = bounds
    shape.path = icon.path.copy(using: &transform)
    shape.fillRule = icon.evenOdd ? .evenOdd : .nonZero
    shape.fillColor = (icon.color ?? Palette.textPrimary).resolvedColor(with: traitCollection).cgColor
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    setNeedsLayout()
  }
}
