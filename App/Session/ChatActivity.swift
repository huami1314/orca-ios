import OrcaCore
import UIKit

/// What a tool call is, as the official transcript classifies it (native-chat-tool-icon.ts): it picks the
/// run's icon and the words of its one-line summary.
enum ToolCategory: CaseIterable {
  case read, search, listFiles, command, fileChange, webSearch, browser, integration, subagent, plan, other

  /// Asking the person is its own row (the question), never a counted call (isNativeChatAskCall).
  static func isAsk(_ call: TranscriptItem.ToolCall) -> Bool {
    ["askuserquestion", "ask_user_question", "request_user_input", "askuser"].contains(call.name.lowercased())
  }

  static func of(_ call: TranscriptItem.ToolCall) -> ToolCategory {
    let word = call.name.trimmingCharacters(in: .whitespaces).lowercased()
    if word.hasPrefix("mcp__") { return .integration }
    if ["bash", "shell", "exec", "local_shell", "exec_command", "run_command", "command"].contains(word) {
      return (call.input["command"]?.stringValue ?? "").contains("orca browser") ? .browser : .command
    }
    if TranscriptItem.ToolCall.isWebSearch(name: word) { return .webSearch }
    switch word {
    case "read", "read_file", "view": return .read
    case "search", "grep", "glob": return .search
    case "list", "ls": return .listFiles
    case "diff", "edit", "multiedit", "write", "notebookedit", "apply_patch", "str_replace_based_edit_tool": return .fileChange
    case "task", "agent", "subagent": return .subagent
    case "todowrite", "update_plan": return .plan
    default: return .other
    }
  }

  var icon: Lucide {
    switch self {
    case .read: .eye
    case .search: .search
    case .listFiles: .folder
    case .command: .squareTerminal
    case .fileChange: .pencil
    case .webSearch, .browser: .globe
    case .integration: .plug
    case .subagent: .bot
    case .plan: .listChecks
    case .other: .wrench
    }
  }

  /// One clause of the run's sentence ("已运行 2 条命令"), live or settled (chat.toolRun.*).
  func clause(_ count: Int, live: Bool) -> String {
    let stem: String
    switch self {
    case .read: stem = "Read"
    case .search: stem = "Search"
    case .listFiles: stem = "ListFiles"
    case .command: stem = "Unknown"
    case .fileChange: stem = "FileChange"
    case .webSearch: stem = "WebSearch"
    case .integration: stem = "McpToolCall"
    case .subagent: stem = "SubAgentActivity"
    case .other: stem = "Other"
    case .browser:
      return count == 1
        ? Self.word(live ? "liveBrowserOnce" : "settledBrowserOnce", live ? "Using the browser" : "Used the browser")
        : String.localizedStringWithFormat(Self.word(live ? "liveBrowserTimes" : "settledBrowserTimes", "%lld"), count)
    case .plan:
      return count == 1
        ? Self.word(live ? "liveTodoListOnce" : "settledTodoListOnce", live ? "Updating the plan" : "Updated the plan")
        : String.localizedStringWithFormat(Self.word(live ? "liveTodoListTimes" : "settledTodoListTimes", "%lld"), count)
    }
    // The catalog keeps i18next's _one/_other pair as one key with plural variations.
    let key = (live ? "live" : "settled") + stem
    return String.localizedStringWithFormat(Self.word(key, "%lld"), count)
  }

  private static func word(_ key: String, _ fallback: String) -> String {
    Bundle.main.localizedString(forKey: "chat.toolRun.\(key)", value: fallback, table: nil)
  }

  /// The run's sentence: its categories in first-use order, joined as the official copy joins them.
  static func sentence(for calls: [TranscriptItem.ToolCall], live: Bool) -> String {
    var order: [ToolCategory] = []
    var counts: [ToolCategory: Int] = [:]
    for call in calls {
      let category = of(call)
      if counts[category] == nil { order.append(category) }
      counts[category, default: 0] += 1
    }
    let clauses = order.map { $0.clause(counts[$0] ?? 0, live: live) }
    switch clauses.count {
    case 0: return ""
    case 1: return clauses[0]
    case 2: return String(format: word("pair", "%1$@ and %2$@"), clauses[0], clauses[1])
    default:
      let head = clauses.dropLast().joined(separator: word("separator", ", "))
      return String(format: word("list", "%1$@, and %2$@"), head, clauses.last!)
    }
  }

  /// The icon a run shows: its one shared category's, else the generic wrench.
  static func icon(for calls: [TranscriptItem.ToolCall]) -> Lucide {
    let categories = Set(calls.map(of))
    return categories.count == 1 ? categories.first!.icon : .wrench
  }
}

/// One quiet activity line: a muted icon, the words, a spinner while it runs,
/// and a chevron when it opens. A step waiting on the person turns amber.
/// The thread down a turn's activity (connected rows, as iGhostVT draws them): a hairline above and below a
/// row's icon, drawn where the row before or after it is also activity, so a run of calls, thoughts and notes
/// reads as one line with its steps on it. Opened thoughts and calls continue it on their own rails.
final class TimelineRails {
  private let up = UIView()
  private let down = UIView()

  /// Adds the rails to `view`, centred on an icon `iconSize` wide at the row's leading margin and on `anchor`.
  init(in view: UIView, iconSize: CGFloat, centeredOn anchor: NSLayoutYAxisAnchor) {
    for rail in [up, down] {
      rail.backgroundColor = Palette.borderSubtle
      rail.isHidden = true
      rail.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(rail)
    }
    let x = Spacing.lg + 7
    NSLayoutConstraint.activate([
      up.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: x),
      up.widthAnchor.constraint(equalToConstant: 1),
      up.topAnchor.constraint(equalTo: view.topAnchor),
      up.bottomAnchor.constraint(equalTo: anchor, constant: -(iconSize / 2 + 4)),
      down.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: x),
      down.widthAnchor.constraint(equalToConstant: 1),
      down.topAnchor.constraint(equalTo: anchor, constant: iconSize / 2 + 4),
      down.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  func show(up joinsAbove: Bool, down joinsBelow: Bool) {
    up.isHidden = !joinsAbove
    down.isHidden = !joinsBelow
  }
}

final class ActivityRowView: UIView {
  private var rails: TimelineRails?
  private let icon = LucideView(.wrench, size: 15, strokeWidth: 2, color: Palette.textMuted)
  private let label = TextLabel(size: ChatProse.metaSize, color: Palette.textSecondary, lines: 1)
  private let detail = TextLabel(size: ChatProse.metaSize, color: Palette.textMuted, lines: 1)
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let chevron = LucideView(.chevronRight, size: 13, strokeWidth: 2, color: Palette.textMuted)

  init() {
    super.init(frame: .zero)
    spinner.transform = CGAffineTransform(scaleX: 0.65, y: 0.65)
    spinner.hidesWhenStopped = true
    detail.lineBreakMode = .byTruncatingTail
    detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    let row = UIStackView(arrangedSubviews: [spinner, icon, label, detail, chevron, UIView()])
    row.spacing = Spacing.sm
    row.alignment = .center
    row.setCustomSpacing(4, after: spinner)
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
      row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
    ])
    rails = TimelineRails(in: self, iconSize: 15, centeredOn: row.centerYAnchor)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// Joins this row to the activity above and below it.
  func connect(up: Bool, down: Bool) { rails?.show(up: up, down: down) }

  func show(icon glyph: Lucide, text: String, detail extra: String? = nil, running: Bool, attention: Bool = false, opens: Bool = true, expanded: Bool = false) {
    icon.icon = glyph
    icon.color = attention ? Palette.statusAmber : Palette.textMuted
    label.text = text
    label.textColor = attention ? Palette.statusAmber : Palette.textSecondary
    detail.text = extra
    detail.isHidden = (extra ?? "").isEmpty
    // A running line swaps its icon for the spinner, in the same slot.
    if running { spinner.startAnimating() } else { spinner.stopAnimating() }
    icon.isHidden = running
    chevron.isHidden = !opens
    chevron.transform = expanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
    accessibilityLabel = [text, extra].compactMap { $0 }.joined(separator: ", ")
    accessibilityTraits = opens ? .button : .staticText
    isAccessibilityElement = true
  }
}

/// A finished thought, opened in place under its row: the muted reasoning text.
final class ThoughtTextView: UIView {
  private let label = TextLabel(size: ChatProse.metaSize, color: Palette.textMuted, lines: 0)

  init() {
    super.init(frame: .zero)
    let rule = UIView()
    rule.backgroundColor = Palette.borderSubtle
    rule.translatesAutoresizingMaskIntoConstraints = false
    addSubview(rule)
    addSubview(label)
    NSLayoutConstraint.activate([
      rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg + 7),
      rule.widthAnchor.constraint(equalToConstant: 1),
      rule.topAnchor.constraint(equalTo: topAnchor),
      rule.bottomAnchor.constraint(equalTo: bottomAnchor),
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg + 23),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
      label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// The row should re-measure: a streaming thought grew a line.
  var onHeightChange: (() -> Void)?
  private var identity: String?
  private var full: [Character] = []
  private var shown = 0
  private var link: CADisplayLink?
  private var lastHeight: CGFloat = 0

  /// Reasoning arrives in pieces that start and end with blank lines; drawn as is, the gaps between pieces
  /// pile up. Each piece shows trimmed, with at most one blank line between its paragraphs. While the thought
  /// is still being written, what arrives types out over a moment instead of landing as a block.
  func show(_ text: String, id: String, streaming: Bool) {
    let target = Array(
      text.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n[ \t]*(\n[ \t]*)+", with: "\n\n", options: .regularExpression))
    let grew = id == identity && target.count > shown && target.starts(with: full.prefix(shown))
    identity = id
    full = target
    if streaming && grew {
      if link == nil {
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
      }
    } else {
      stop()
      shown = full.count
      label.text = String(full)
    }
  }

  @objc private func step() {
    let remaining = full.count - shown
    guard remaining > 0, window != nil else {
      stop()
      shown = full.count
      label.text = String(full)
      return
    }
    // About a third of a second for whatever is pending, never slower than a couple of characters a frame.
    shown += max(2, Int((Double(remaining) / 20).rounded(.up)))
    shown = min(shown, full.count)
    label.text = String(full.prefix(shown))
    let height = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height
    if abs(height - lastHeight) > 0.5 {
      lastHeight = height
      invalidateIntrinsicContentSize()
      onHeightChange?()
    }
    if shown == full.count { stop() }
  }

  private func stop() {
    link?.invalidate()
    link = nil
  }
}

/// The files a turn changed (MobileNativeChatTurnDiffRollup): a count with its +/−, then a row per file
/// that opens its patch.
final class ChangedFilesView: UIView {
  struct File {
    let path: String
    let patch: String
    let truncated: Bool
    var added: Int { patch.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count }
    var removed: Int { patch.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count }
  }

  var onOpen: ((File) -> Void)?
  private let stack = UIStackView()

  init() {
    super.init(frame: .zero)
    let card = UIView()
    card.layer.cornerRadius = Radius.surface
    card.layer.cornerCurve = .continuous
    card.layer.borderWidth = 1
    card.layer.borderColor = Palette.borderSubtle.cgColor
    card.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)
    addSubview(card)
    NSLayoutConstraint.activate([
      card.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.sm),
      card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.sm),
      card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
      card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Spacing.sm),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Spacing.sm),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Spacing.md),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Spacing.md),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    stack.superview?.layer.borderColor = Palette.borderSubtle.cgColor
  }

  func show(_ files: [File]) {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    let added = files.reduce(0) { $0 + $1.added }
    let removed = files.reduce(0) { $0 + $1.removed }
    let title = TextLabel(
      String(
        format: String(localized: "components.native-chat.turnDiff.changedFiles", defaultValue: "%lld changed files"), files.count),
      size: ChatProse.metaSize, color: Palette.textSecondary)
    let head = UIStackView(arrangedSubviews: [title, Self.counts(added, removed)])
    if files.contains(where: \.truncated) {
      head.addArrangedSubview(
        TextLabel(
          String(localized: "components.native-chat.turnDiff.partial", defaultValue: "Partial diff"), size: ChatProse.metaSize,
          color: Palette.textMuted))
    }
    head.addArrangedSubview(UIView())
    head.spacing = Spacing.sm
    head.alignment = .center
    head.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
    stack.addArrangedSubview(head)
    for file in files {
      let name = (file.path as NSString).lastPathComponent
      let folder = (file.path as NSString).deletingLastPathComponent
      let chevron = LucideView(.chevronRight, size: 13, strokeWidth: 2, color: Palette.textMuted)
      let nameLabel = TextLabel(name, size: ChatProse.metaSize, color: Palette.textPrimary, lines: 1)
      let folderLabel = TextLabel(folder, size: ChatProse.metaSize, color: Palette.textMuted, lines: 1)
      folderLabel.lineBreakMode = .byTruncatingHead
      folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      let row = UIStackView(arrangedSubviews: [chevron, nameLabel, folderLabel, UIView(), Self.counts(file.added, file.removed)])
      row.spacing = Spacing.sm
      row.alignment = .center
      row.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
      let tap = UIButton(type: .custom)
      tap.addAction(UIAction { [weak self] _ in self?.onOpen?(file) }, for: .primaryActionTriggered)
      tap.accessibilityLabel = file.path
      tap.translatesAutoresizingMaskIntoConstraints = false
      row.addSubview(tap)
      tap.pin(to: row)
      stack.addArrangedSubview(row)
    }
  }

  private static func counts(_ added: Int, _ removed: Int) -> UIView {
    let plus = TextLabel("+\(added)", size: ChatProse.metaSize, color: Palette.statusGreen, tabular: true)
    let minus = TextLabel("−\(removed)", size: ChatProse.metaSize, color: Palette.statusRed, tabular: true)
    let row = UIStackView(arrangedSubviews: [plus, minus])
    row.spacing = 6
    return row
  }
}

/// A file's patch from the changed-files card: coloured +/− lines, monospaced, scrolling both ways.
final class PatchSheetController: UIViewController {
  private let file: ChangedFilesView.File

  init(file: ChangedFilesView.File) {
    self.file = file
    super.init(nibName: nil, bundle: nil)
    title = (file.path as NSString).lastPathComponent
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  static func sheet(_ file: ChangedFilesView.File) -> UIViewController {
    let navigation = UINavigationController(rootViewController: PatchSheetController(file: file))
    if let sheet = navigation.sheetPresentationController {
      sheet.detents = [.large()]
      sheet.prefersGrabberVisible = true
    }
    return navigation
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgBase
    navigationItem.subtitle = file.path
    navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
      self?.dismiss(animated: true)
    })
    let text = UITextView()
    text.isEditable = false
    text.backgroundColor = .clear
    text.textContainerInset = UIEdgeInsets(top: Spacing.md, left: Spacing.md, bottom: Spacing.xl, right: Spacing.md)
    let output = NSMutableAttributedString()
    let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    for line in file.patch.split(separator: "\n", omittingEmptySubsequences: false) {
      let color: UIColor =
        line.hasPrefix("+") ? Palette.statusGreen : line.hasPrefix("-") ? Palette.statusRed : line.hasPrefix("@@") ? Palette.accentBlue
        : Palette.textSecondary
      output.append(NSAttributedString(string: line + "\n", attributes: [.font: font, .foregroundColor: color]))
    }
    text.attributedText = output
    text.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(text)
    text.pin(to: view)
  }
}

/// A question or approval: a half-height glass sheet that opens on its own when one
/// arrives, one question a page with its choices as glass buttons, single or multiple choice, its own words
/// when the question takes them (they replace the choices), Previous and Next, and Submit once every
/// question that needs an answer has one. Closing never answers; the transcript keeps a line to reopen it.
final class PromptSheetController: UIViewController, UITextViewDelegate {
  enum Response {
    case option(String)
    case answers([TranscriptItem.Answer])
  }

  private let item: TranscriptItem
  private let prompt: TranscriptItem.Prompt
  private let onAnswer: (Response) async -> String?
  /// The pages: the structured questions, or one made of the prompt itself.
  private let questions: [TranscriptItem.Question]
  private let structured: Bool
  private var page = 0
  private var picked: [String: [String]] = [:]
  private var typed: [String: String] = [:]
  private var submitting = false

  private let scroll = UIScrollView()
  private let stack = UIStackView()
  private let error = TextLabel(size: 14, color: Palette.statusRed, lines: 0)
  private var previousButton: UIBarButtonItem!
  private var nextButton: UIBarButtonItem!

  init?(item: TranscriptItem, onAnswer: @escaping (Response) async -> String?) {
    switch item.body {
    case .approval(let prompt), .question(let prompt): self.prompt = prompt
    default: return nil
    }
    self.item = item
    self.onAnswer = onAnswer
    structured = !prompt.questions.isEmpty
    questions =
      structured
      ? prompt.questions
      : [.init(id: "", text: prompt.title, header: nil, multiSelect: false, options: prompt.options, freeText: nil, skippable: false)]
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  var isApproval: Bool { if case .approval = item.body { true } else { false } }

  static func sheet(item: TranscriptItem, onAnswer: @escaping (Response) async -> String?) -> UIViewController? {
    guard let controller = PromptSheetController(item: item, onAnswer: onAnswer) else { return nil }
    let navigation = UINavigationController(rootViewController: controller)
    if let sheet = navigation.sheetPresentationController {
      // Half height on the system's glass sheet; drag up for long prompts.
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.prefersScrollingExpandsWhenScrolledToEdge = true
    }
    return navigation
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // Clear, so the sheet's own Liquid Glass shows through.
    view.backgroundColor = .clear
    navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
      self?.dismiss(animated: true)
    })
    let submit = UIBarButtonItem(
      title: String(localized: "orcaios.chat.submit", defaultValue: "Submit"), style: .prominent, target: nil, action: nil)
    submit.primaryAction = UIAction(title: submit.title ?? "") { [weak self] _ in self?.submit() }
    navigationItem.rightBarButtonItem = submit
    previousButton = UIBarButtonItem(
      title: String(localized: "orcaios.chat.previous", defaultValue: "Previous"),
      primaryAction: UIAction { [weak self] _ in self?.turn(to: (self?.page ?? 1) - 1) })
    nextButton = UIBarButtonItem(
      title: String(localized: "orcaios.chat.next", defaultValue: "Next"),
      primaryAction: UIAction { [weak self] _ in self?.turn(to: (self?.page ?? 0) + 1) })
    toolbarItems = [previousButton, .flexibleSpace(), nextButton]

    scroll.alwaysBounceVertical = true
    scroll.keyboardDismissMode = .interactive
    scroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll)
    scroll.pin(to: view)
    stack.axis = .vertical
    stack.spacing = Spacing.sm
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.md),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xl),
      stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.lg),
      stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg),
    ])
    draw()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setToolbarHidden(questions.count < 2, animated: false)
  }

  // MARK: State

  private func answered(_ question: TranscriptItem.Question) -> Bool {
    let words = (typed[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return !(picked[question.id] ?? []).isEmpty || !words.isEmpty || (question.freeText?.allowEmpty == true && typed[question.id] != nil)
  }

  private var complete: Bool { questions.allSatisfy { answered($0) || $0.skippable } }

  private func turn(to index: Int) {
    guard questions.indices.contains(index) else { return }
    view.endEditing(true)
    page = index
    UISelectionFeedbackGenerator().selectionChanged()
    draw()
  }

  private func toggle(_ option: TranscriptItem.PromptOption, in question: TranscriptItem.Question) {
    guard !submitting else { return }
    UISelectionFeedbackGenerator().selectionChanged()
    var ids = picked[question.id] ?? []
    if question.multiSelect {
      if let at = ids.firstIndex(of: option.id) { ids.remove(at: at) } else { ids.append(option.id) }
    } else {
      ids = [option.id]
    }
    picked[question.id] = ids
    // A choice replaces typed words, as typed words replace choices.
    typed[question.id] = nil
    draw()
    // A single choice on a page that isn't the last moves on.
    if !question.multiSelect, page < questions.count - 1 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.turn(to: (self?.page ?? 0) + 1) }
    }
  }

  func textViewDidChange(_ textView: UITextView) {
    let question = questions[page]
    typed[question.id] = textView.text
    if !textView.text.isEmpty, !(picked[question.id] ?? []).isEmpty {
      picked[question.id] = []
      // Redraw the choices without taking the keyboard away.
      for case let button as UIButton in stack.arrangedSubviews {
        if let option = question.options.first(where: { $0.id == button.accessibilityIdentifier }) {
          button.configuration = Self.optionLook(option, selected: false, multi: question.multiSelect)
        }
      }
    }
    textView.viewWithTag(9)?.isHidden = !textView.text.isEmpty
    updateBars()
  }

  // MARK: Drawing

  private func draw() {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    let question = questions[page]
    title =
      questions.count > 1
      ? "\(page + 1) / \(questions.count)"
      : isApproval
        ? String(localized: "orcaios.chat.approvalTitle", defaultValue: "Needs your approval")
        : String(localized: "orcaios.chat.questionTitle", defaultValue: "Question")
    if let header = question.header, !header.isEmpty {
      stack.addArrangedSubview(TextLabel(header.uppercased(), size: 12, weight: .semibold, color: Palette.textMuted))
    }
    stack.addArrangedSubview(TextLabel(question.text, size: 19, weight: .semibold, lines: 0))
    if !structured, let detail = prompt.detail, !detail.isEmpty {
      let body = TextLabel(size: 15, color: Palette.textSecondary, lines: 0)
      body.text = detail
      stack.addArrangedSubview(body)
    }
    if question.multiSelect {
      stack.addArrangedSubview(
        TextLabel(String(localized: "orcaios.chat.chooseAny", defaultValue: "Choose any that apply"), size: 13, color: Palette.textMuted))
    }
    stack.setCustomSpacing(Spacing.md, after: stack.arrangedSubviews.last!)
    let chosen = picked[question.id] ?? []
    for option in question.options {
      let button = UIButton(
        configuration: Self.optionLook(option, selected: chosen.contains(option.id), multi: question.multiSelect),
        primaryAction: UIAction { [weak self] _ in self?.toggle(option, in: question) })
      button.accessibilityIdentifier = option.id
      button.accessibilityTraits = chosen.contains(option.id) ? [.button, .selected] : .button
      button.contentHorizontalAlignment = .leading
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
      stack.addArrangedSubview(button)
    }
    if let freeText = question.freeText {
      let field = UITextView()
      field.font = .systemFont(ofSize: 16)
      field.backgroundColor = Palette.bgRaised.withAlphaComponent(0.6)
      field.layer.cornerRadius = Radius.control
      field.layer.cornerCurve = .continuous
      field.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
      field.isScrollEnabled = false
      field.text = typed[question.id]
      field.delegate = self
      field.heightAnchor.constraint(greaterThanOrEqualToConstant: freeText.multiline ? 88 : 46).isActive = true
      let placeholder = UILabel()
      placeholder.text = freeText.placeholder ?? String(localized: "chat.ask.answerPlaceholder", defaultValue: "Type your answer")
      placeholder.textColor = Palette.textMuted
      placeholder.font = field.font
      placeholder.tag = 9
      placeholder.isHidden = !(field.text ?? "").isEmpty
      placeholder.translatesAutoresizingMaskIntoConstraints = false
      field.addSubview(placeholder)
      NSLayoutConstraint.activate([
        placeholder.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 15),
        placeholder.topAnchor.constraint(equalTo: field.topAnchor, constant: 12),
      ])
      stack.setCustomSpacing(Spacing.md, after: stack.arrangedSubviews.last!)
      stack.addArrangedSubview(field)
    }
    error.isHidden = true
    stack.addArrangedSubview(error)
    updateBars()
  }

  private func updateBars() {
    previousButton.isEnabled = page > 0 && !submitting
    nextButton.isEnabled = page < questions.count - 1 && !submitting
    navigationItem.rightBarButtonItem?.isEnabled = complete && !submitting
  }

  /// An answer as a glass button; the picked one is the tinted, prominent glass.
  private static func optionLook(_ option: TranscriptItem.PromptOption, selected: Bool, multi: Bool) -> UIButton.Configuration {
    var look = selected ? UIButton.Configuration.prominentGlass() : UIButton.Configuration.glass()
    look.title = option.label
    look.subtitle = option.description
    look.titleAlignment = .leading
    look.cornerStyle = .large
    look.baseForegroundColor = selected ? .white : Palette.textPrimary
    if selected { look.baseBackgroundColor = Palette.accentBlue }
    let mark = multi ? (selected ? "checkmark.square.fill" : "square") : (selected ? "checkmark.circle.fill" : "circle")
    look.image = UIImage(systemName: mark)
    look.imagePadding = 12
    look.contentInsets = .init(top: 12, leading: 14, bottom: 12, trailing: 14)
    return look
  }

  // MARK: Submit

  /// Stays open while the answer travels; a refusal keeps every answer for a retry.
  private func submit() {
    guard complete, !submitting else { return }
    view.endEditing(true)
    let response: Response
    if structured {
      response = .answers(
        questions.compactMap { question in
          let words = (typed[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
          let ids = picked[question.id] ?? []
          if ids.isEmpty && words.isEmpty && typed[question.id] == nil { return nil }
          return .init(questionId: question.id, optionIds: words.isEmpty ? ids : [], other: words.isEmpty ? nil : words)
        })
    } else {
      guard let id = picked[""]?.first else { return }
      response = .option(id)
    }
    submitting = true
    updateBars()
    Task {
      if let refusal = await onAnswer(response) {
        submitting = false
        updateBars()
        error.text = refusal
        error.isHidden = false
        UINotificationFeedbackGenerator().notificationOccurred(.error)
      } else {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss(animated: true)
      }
    }
  }
}
