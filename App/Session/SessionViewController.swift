import OrcaCore
import UIKit

/// A workspace's session (session/MobileSessionRouteScreen.tsx): the system navigation bar with the branch
/// as subtitle, the official tab strip, and the active tab's content (a chat for agent sessions).
final class SessionViewController: UIViewController {
  private let session: HostSession
  private let worktreeId: String
  private let strip = SessionTabStrip()
  private let content = UIView()
  private let stripEdge = UIScrollEdgeElementContainerInteraction()
  private var tabs = SessionTabs()
  private var tabsTask: Task<Void, Never>?
  private var shownTabId: String?
  private var chats: [String: ChatViewController] = [:]
  private var current: UIViewController?
  private var resolvingPath = false
  private var shownTabKind: SessionTab.Kind?
  private var shownTerminalChat: TerminalChatSource?
  private var terminalChatChoices: [String: Bool] = [:]
  private var terminalChatToggle: UIBarButtonItem?
  private var terminalGround: UIColor?
  private var shownTerminalColors: [String: String]?
  private var originalNavigationStyle: UIUserInterfaceStyle?
  private var workspaceVisible = false
  /// The host has answered with its tabs, so none means none rather than not yet.
  private var tabsLoaded = false

  /// The chat to bring to the front once the tabs arrive, as an item or a past session asked.
  private var focusSessionId: String?
  private var focusPaneKey: String?
  /// The profile a new browser tab opens in; nil lets the host apply desktop's rule (repo, workspace, host default).
  private var browserProfileId: String?
  /// The title for a workspace the list doesn't carry, such as the Floating Workspace.
  var fallbackTitle: String?

  init(session: HostSession, worktreeId: String, sessionId: String? = nil, paneKey: String? = nil) {
    self.session = session
    self.worktreeId = worktreeId
    focusSessionId = sessionId
    focusPaneKey = paneKey
    super.init(nibName: nil, bundle: nil)
    hidesBottomBarWhenPushed = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit { tabsTask?.cancel() }

  private var selector: String { "id:\(worktreeId)" }

  /// The bot whose home this workspace is, if any.
  private var bot: Bot? { session.bots.bots.first { $0.homeWorktreeId == worktreeId } }
  private lazy var botTitle = BotTitleView()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgBase
    navigationItem.largeTitleDisplayMode = .never
    // Built as it opens: its toggles read their current state.
    let more = UIBarButtonItem(
      image: Lucide.ellipsis.image(size: 20, strokeWidth: 2),
      menu: UIMenu(children: [
        UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.moreMenu().children ?? []) }
      ]))
    if bot != nil {
      // A bot's home: its items instead of source control, and its face beside its name.
      let items = UIBarButtonItem(
        image: Lucide.listChecks.image(size: 20, strokeWidth: 2), primaryAction: UIAction { [weak self] _ in self?.openItems() })
      items.accessibilityLabel = String(localized: "session.header.items", defaultValue: "Items")
      navigationItem.rightBarButtonItems = [more, items]
      navigationItem.titleView = botTitle
    } else {
      let branch = UIBarButtonItem(
        image: Lucide.gitBranch.image(size: 20, strokeWidth: 2), primaryAction: UIAction { [weak self] _ in self?.openSourceControl() })
      branch.accessibilityLabel = String(localized: "session.header.sourceControl", defaultValue: "Source control")
      navigationItem.rightBarButtonItems = [more, branch]
    }

    strip.onSelect = { [weak self] tab in
      guard let self else { return }
      self.show(tab)
      self.updateStrip()
      let api = self.session.api
      let selector = self.selector
      Task { await api.activateTab(tab.id, worktree: selector) }
    }
    strip.onClose = { [weak self] tab in
      guard let self else { return }
      let api = self.session.api
      let selector = self.selector
      self.run { try await api.closeTab(tab.id, worktree: selector) }
    }
    strip.newTabMenu = { [weak self] in self?.newTabMenu() ?? UIMenu() }
    stripEdge.edge = .top
    strip.addInteraction(stripEdge)
    content.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(content)
    view.addSubview(strip)
    NSLayoutConstraint.activate([
      strip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      strip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      strip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      // Under the bar and the strip: a chat scrolls beneath both and the soft edge fades it.
      content.topAnchor.constraint(equalTo: view.topAnchor),
      content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    let api = session.api
    let selector = selector
    Task { await api.activate(worktree: selector) }
    // The tabs this workspace had last time show at once, so its chat opens without waiting for the desktop.
    let tabsCache = FrameCache(name: "tabs-" + session.host.id.uuidString + "-" + worktreeId)
    if let cached = tabsCache.load().last {
      let restored = SessionTabs(cached)
      if !restored.tabs.isEmpty, !restored.removed { apply(restored, cached: true) }
    }
    tabsTask = Task { [weak self] in
      let subscription = await api.tabs(worktree: selector)
      do {
        for try await frame in subscription.events {
          tabsCache.record(frame, isSnapshot: true)
          self?.apply(SessionTabs(frame))
        }
      } catch {}
    }
  }

  override func updateProperties() {
    super.updateProperties()
    if let active = tabs.tabs.first(where: { $0.id == shownTabId }), active.terminalHandle != nil {
      show(active)
    }
    let worktree = session.worktree(id: worktreeId)
    title = worktree?.displayName ?? fallbackTitle
    let status = HostConnectionPresentation(session.connectionState)
    // "● 正在工作 · main": what the agent is doing in words, then the branch; offline, the connection's state.
    let state = shownState(worktree)
    let word: String =
      switch state {
      case "working", "monitoring": String(localized: "sidebar.cardSlot.working", defaultValue: "Working")
      case "permission", "waiting", "blocked": String(localized: "workspace.activity.permission", defaultValue: "Needs permission")
      default: String(localized: "bots.row.idle", defaultValue: "Idle")
      }
    let branch = (worktree?.branch ?? "").replacingOccurrences(of: "refs/heads/", with: "")
    let line = ([status.connected ? word : status.label] + (status.connected && !branch.isEmpty ? [branch] : []))
      .joined(separator: " · ")
    let subtitle = NSMutableAttributedString(
      string: "● ",
      attributes: [
        .foregroundColor: status.connected ? AgentStatusDot.color(for: state == "idle" ? "done" : state) : status.dot,
        .font: UIFont.systemFont(ofSize: 11),
      ])
    subtitle.append(NSAttributedString(string: line, attributes: [.foregroundColor: Palette.textSecondary]))
    navigationItem.attributedSubtitle = AttributedString(subtitle)
    if let bot {
      // The title view carries the bot's own line; the branch is the bot's business.
      navigationItem.attributedSubtitle = nil
      botTitle.show(bot: bot, status: BotRowConfiguration.statusWord(bot, home: worktree), dot: status.dot)
    }
    updateStrip()
  }

  /// `cached`: the tabs from last time, shown until the desktop's own list arrives; an empty workspace isn't
  /// concluded from them.
  private func apply(_ next: SessionTabs, cached: Bool = false) {
    var next = next
    if tabsLoaded && !cached { next.retainTerminalChats(from: tabs) }
    tabs = next
    tabsLoaded = !cached
    if !cached {
      let terminalIDs = Set(next.tabs.compactMap { tab in
        if case .terminal = tab.kind { return tab.id }
        return nil
      })
      terminalChatChoices = terminalChatChoices.filter { terminalIDs.contains($0.key) }
    }
    if next.removed {
      navigationController?.popViewController(animated: true)
      return
    }
    if let tab = next.agentTab(sessionId: focusSessionId, paneKey: focusPaneKey) {
      show(tab)
      updateStrip()
      if !cached {
        focusSessionId = nil
        focusPaneKey = nil
        let api = session.api
        let selector = selector
        Task { await api.activateTab(tab.id, worktree: selector) }
      }
      return
    }
    let active = next.tabs.first { $0.id == next.activeTabId } ?? next.tabs.first
    show(active)
    updateStrip()
  }

  /// The state the header and tab show. With a chat on screen, it is whether that chat's agent is running a
  /// turn: the desktop's workspace state also counts background tasks and an active goal as working, which
  /// leaves "Working" up while nothing runs. Otherwise the workspace's own state.
  private func shownState(_ worktree: Worktree?) -> String {
    if let chat = current as? ChatViewController {
      let waiting = worktree?.displayStatus == "permission"
      return waiting ? "permission" : chat.model.isWorking ? "working" : "idle"
    }
    let state = worktree?.displayStatus ?? "idle"
    return state == "monitoring" ? "idle" : state
  }

  private func updateStrip() {
    let active = tabs.tabs.first { $0.id == shownTabId }
    let agentState = shownState(session.worktree(id: worktreeId))
    // A /btw fork lives in its sheet, not the strip.
    let listed = tabs.tabs.filter { tab in
      if case .agentSession(let id, _) = tab.kind { return !sideSessions.contains(id) }
      return true
    }
    strip.show(tabs: listed, shownId: active?.id, agentState: agentState, botHome: bot != nil)
  }

  private func show(_ tab: SessionTab?) {
    let readable = tab.flatMap(readableTerminalChat)
    let useChat = tab.map { terminalChatChoices[$0.id] ?? $0.prefersTerminalChat } ?? false
    let terminalChat = useChat ? readable : nil
    let matchTerminal = readable != nil || (!tabsLoaded && tab?.terminalChat != nil)
    let ground = matchTerminal ? TerminalAppearance.background(for: traitCollection, colors: tab?.terminalColors) : nil
    let terminalColors = matchTerminal ? tab?.terminalColors : nil
    let appearanceChanged = ground != terminalGround || (terminalChat == nil && terminalColors != shownTerminalColors)
    setTerminalGround(ground)
    shownTerminalColors = terminalColors
    updateTerminalChatToggle(available: readable != nil, showingChat: terminalChat != nil)
    // A browser tab's address and back/forward change under the same page; the pane on screen takes them.
    if let tab, tab.id == shownTabId, let state = tab.browser {
      (current as? BrowserTabViewController)?.apply(state)
    }
    // The same tab is shown again when what it holds changed: a new terminal tab gets its terminal a moment
    // after it appears.
    guard
      tab?.id != shownTabId || tab?.kind != shownTabKind || terminalChat != shownTerminalChat || appearanceChanged
        || (tab == nil && tabsLoaded && !(current is NoTabsViewController))
    else { return }
    shownTabId = tab?.id
    shownTabKind = tab?.kind
    shownTerminalChat = terminalChat
    let next: UIViewController
    switch tab?.kind {
    case .agentSession(let sessionId, _):
      if let existing = chats[sessionId] {
        next = existing
      } else {
        let worktree = session.worktree(id: worktreeId)
        let model = ChatSessionModel(
          api: session.api, sessionId: sessionId, capabilities: session.status?.capabilities ?? [],
          connectionId: worktree.flatMap { session.repo(id: $0.repoId)?.connectionId })
        let chat = ChatViewController(model: model)
        chat.imageLoader = ChatImageLoader(api: session.api, worktreeId: worktreeId)
        chat.isBotChat = bot != nil
        let api = session.api
        let searchIn = worktreeId
        chat.searchFiles = { query in (try? await api.searchPaths(worktreeId: searchIn, query: query)) ?? [] }
        let agentType: String? = { if case .agentSession(_, let agent) = tab?.kind { return agent } else { return nil } }()
        chat.onActivity = { [weak self] working, detail in
          guard let self, let worktree = self.session.worktree(id: self.worktreeId) else { return }
          // The header and tab follow the chat's own turn.
          self.updateStrip()
          self.setNeedsUpdateProperties()
          AgentActivityCenter.shared.reportChat(
            hostId: self.session.host.id, hostName: self.session.name, worktree: worktree, agentType: agentType,
            working: working, detail: detail)
        }
        chat.onOpenPath = { [weak self] path in self?.openPath(path) }
        // Fork from a response: a new chat with the same agent, holding this one through that answer.
        chat.onFork = { [weak self] itemId in
          guard let self else { return }
          let api = self.session.api
          let selector = self.selector
          self.run { try await api.createChat(agent: agentType ?? "claude", worktree: selector, forkFrom: (sessionId, itemId)) }
        }
        chat.onSideQuestion = { [weak self] question, itemId in
          guard let self else { return }
          let api = self.session.api
          let selector = self.selector
          let worktree = self.session.worktree(id: self.worktreeId)
          let model = { (id: String) in
            ChatSessionModel(
              api: api, sessionId: id, capabilities: self.session.status?.capabilities ?? [],
              connectionId: worktree.flatMap { self.session.repo(id: $0.repoId)?.connectionId })
          }
          self.run {
            let side = try await api.createChat(
              agent: agentType ?? "claude", worktree: selector, forkFrom: (sessionId, itemId), firstMessage: question)
            self.presentSideAnswer(question: question, model: model(side))
          }
        }
        chats[sessionId] = chat
        next = chat
      }
    case .terminal(nil):
      // The desktop is still starting this tab's terminal; the tab shows it once it has a handle.
      next = PendingTerminalViewController()
    case .terminal(let handle?):
      if let terminalChat {
        let chat = ChatViewController(model: ChatSessionModel(api: session.api, terminal: terminalChat), terminalGround: ground)
        chat.readOnly = true
        chat.imageLoader = ChatImageLoader(api: session.api, worktreeId: worktreeId)
        chat.onOpenPath = { [weak self] in self?.openPath($0) }
        chat.onActivity = { [weak self] _, _ in self?.setNeedsUpdateProperties() }
        next = chat
      } else {
        next = TerminalTabController(
          api: session.api, handle: handle,
          sendsQueryReplies: session.status?.supports(HostCapability.terminalQueryReply) ?? false,
          colors: tab?.terminalColors, matchesTranscript: matchTerminal)
      }
    case .markdown(let path), .file(let path, _):
      // A note or file tab reads as its preview: Markdown rendered, code highlighted.
      next = FilePreviewViewController(session: session, worktreeId: worktreeId, path: path)
    case .browser:
      // The desktop's page, streamed; nil support means the host's capabilities haven't been read yet.
      next = BrowserTabViewController(
        api: session.api, worktreeId: worktreeId, tab: tab?.browser ?? BrowserTabState([:]),
        streamingSupported: session.status?.supports(BrowserCapability.screencast),
        certificateTrustSupported: session.status?.supports(BrowserCertificateTrustCapability.certificateTrust) == true)
    case nil where tabsLoaded:
      let api = session.api
      let selector = selector
      next = NoTabsViewController { [weak self] in self?.run { try await api.createTerminalTab(worktree: selector) } }
    default:
      next = UnsupportedTabViewController(tab: tab)
    }
    (current as? WorkspaceContent)?.close()
    if let chat = current as? ChatViewController, chat.model.isTerminalChat { chat.model.stop() }
    if let current {
      current.willMove(toParent: nil)
      current.view.removeFromSuperview()
      current.removeFromParent()
    }
    addChild(next)
    content.addSubview(next.view)
    next.view.translatesAutoresizingMaskIntoConstraints = false
    let chat = (next as? ChatViewController)?.edgeScrollView
    NSLayoutConstraint.activate([
      next.view.topAnchor.constraint(equalTo: chat != nil ? content.topAnchor : strip.bottomAnchor),
      next.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      next.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      next.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])
    // A chat starts below the strip and scrolls under it; the strip joins the bar's soft edge.
    next.additionalSafeAreaInsets.top = chat != nil ? SessionTabStrip.height : 0
    stripEdge.scrollView = chat
    next.didMove(toParent: self)
    current = next
    setNeedsUpdateProperties()
  }

  private func readableTerminalChat(_ tab: SessionTab) -> TerminalChatSource? {
    guard tabsLoaded, let source = tab.terminalChat else { return nil }
    let repo = session.worktree(id: worktreeId).flatMap { session.repo(id: $0.repoId) }
    return source.isReadable(connectionId: repo?.connectionId, locationKnown: repo != nil) ? source : nil
  }

  private func updateTerminalChatToggle(available: Bool, showingChat: Bool) {
    if available {
      let toggle: UIBarButtonItem
      if let existing = terminalChatToggle {
        toggle = existing
      } else {
        toggle = UIBarButtonItem(primaryAction: UIAction { [weak self] _ in
          guard let self, let active = self.tabs.tabs.first(where: { $0.id == self.shownTabId }) else { return }
          self.terminalChatChoices[active.id] = self.shownTerminalChat == nil
          self.show(active)
          self.updateStrip()
        })
        terminalChatToggle = toggle
        var items = navigationItem.rightBarButtonItems ?? []
        items.insert(toggle, at: min(1, items.count))
        navigationItem.rightBarButtonItems = items
      }
      let label = showingChat
        ? String(localized: "orcaios.session.terminalChatBack", defaultValue: "Back to Terminal")
        : String(localized: "orcaios.session.terminalChatOpen", defaultValue: "View as Chat")
      if toggle.accessibilityLabel != label {
        toggle.image = (showingChat ? Lucide.squareTerminal : Lucide.messageSquareText).image(size: 20)
        toggle.accessibilityLabel = label
      }
    } else if let toggle = terminalChatToggle {
      navigationItem.rightBarButtonItems?.removeAll { $0 === toggle }
      terminalChatToggle = nil
    }
  }

  private func setTerminalGround(_ ground: UIColor?) {
    guard ground != terminalGround else { return }
    terminalGround = ground
    view.backgroundColor = ground ?? Palette.bgBase
    let style = ground.map(TerminalAppearance.interfaceStyle(for:)) ?? .unspecified
    overrideUserInterfaceStyle = style
    strip.useTerminalAppearance(style)
    updateNavigationAppearance()
  }

  private func updateNavigationAppearance() {
    guard let navigation = navigationController else { return }
    if workspaceVisible, overrideUserInterfaceStyle != .unspecified {
      if originalNavigationStyle == nil { originalNavigationStyle = navigation.overrideUserInterfaceStyle }
      navigation.overrideUserInterfaceStyle = overrideUserInterfaceStyle
    } else if let originalNavigationStyle {
      navigation.overrideUserInterfaceStyle = originalNavigationStyle
      self.originalNavigationStyle = nil
    }
    navigation.setNeedsStatusBarAppearanceUpdate()
  }

  // MARK: Side questions

  /// A `/btw` answer in a half sheet over the chat, read once: closing it closes the fork's tab too.
  private func presentSideAnswer(question: String, model: ChatSessionModel) {
    let chat = ChatViewController(model: model)
    chat.readOnly = true
    chat.imageLoader = ChatImageLoader(api: session.api, worktreeId: worktreeId)
    chat.title = question
    let navigation = UINavigationController(rootViewController: chat)
    navigation.navigationBar.prefersLargeTitles = false
    chat.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self, weak navigation] _ in
      navigation?.dismiss(animated: true)
      self?.closeSideChat(model.sessionId)
    })
    if let sheet = navigation.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.prefersScrollingExpandsWhenScrolledToEdge = false
    }
    let sideId = model.sessionId
    sideSessions.insert(sideId)
    updateStrip()
    sideCloser = SheetCloser { [weak self] in self?.closeSideChat(sideId) }
    navigation.presentationController?.delegate = sideCloser
    present(navigation, animated: true)
  }

  private var sideCloser: SheetCloser?
  /// /btw forks, kept out of the strip until their tab is closed.
  private var sideSessions: Set<String> = []

  /// The side chat's tab goes once its answer has been read.
  private func closeSideChat(_ sessionId: String) {
    sideCloser = nil
    let api = session.api
    let selector = selector
    let tabId = tabs.tabs.first { if case .agentSession(sessionId, _) = $0.kind { true } else { false } }?.id
    Task {
      var id = tabId
      // The tab may not have reached the strip yet when the sheet closed fast.
      if id == nil { try? await Task.sleep(for: .seconds(1)) }
      id = id ?? self.tabs.tabs.first { if case .agentSession(sessionId, _) = $0.kind { true } else { false } }?.id
      if let id { try? await api.closeTab(id, worktree: selector) }
      // Closed (or never listed): it may show in the strip again if the close didn't take.
      self.sideSessions.remove(sessionId)
      self.updateStrip()
    }
  }

  // MARK: Panels

  /// A path from a chat, resolved by the desktop as the official file tap does: relative, absolute or `~/…`,
  /// in this workspace, a sibling one, or anywhere the desktop grants a read.
  private func openPath(_ path: String) {
    // One lookup at a time: taps while it runs (or a tap reaching here twice) are dropped.
    guard !resolvingPath else { return }
    resolvingPath = true
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    let api = session.api
    let worktreeId = worktreeId
    // The chat on screen, whose agent wrote the path.
    let shown = tabs.tabs.first { $0.id == shownTabId }
    let chat: (tabId: String, sessionId: String)? = shown.flatMap { tab in
      if case .agentSession(let sessionId, _) = tab.kind { return (tab.id, sessionId) }
      return nil
    }
    let candidates = chat.flatMap { chats[$0.sessionId]?.candidatePaths(for: path) } ?? []
    let others = session.worktrees.filter { $0.id != worktreeId && !$0.isArchived }.map(\.id)
    let relative = !path.hasPrefix("/") && !path.hasPrefix("~")
    Task { [weak self] in
      defer { self?.resolvingPath = false }
      var failure: Error?
      var found: ResolvedPath?
      do {
        found = try await api.resolvePath(worktreeId: worktreeId, pathText: path, chat: chat)
      } catch {
        failure = error
      }
      // Not in this workspace: where the agent was working (its commands and files say), then the desktop's
      // other workspaces. All asked at once; the likeliest answer wins.
      if found == nil, relative {
        found = await withTaskGroup(of: (Int, ResolvedPath?).self) { group in
          for (rank, candidate) in candidates.enumerated() {
            group.addTask { (rank, try? await api.resolvePath(worktreeId: worktreeId, pathText: candidate, chat: chat)) }
          }
          for (index, other) in others.enumerated() {
            group.addTask { (candidates.count + index, try? await api.resolvePath(worktreeId: other, pathText: path)) }
          }
          var best: (Int, ResolvedPath)?
          for await (rank, hit) in group {
            if let hit, best == nil || rank < best!.0 { best = (rank, hit) }
          }
          return best?.1
        }
      }
      guard let self else { return }
      // A desktop that can't resolve paths: a relative path is read in this workspace as written.
      if found == nil, let failure {
        guard relative else {
          let message = (failure as? RPCError).map { $0.message.isEmpty ? $0.code : $0.message } ?? failure.localizedDescription
          self.sayOnce(title: path, message: message)
          return
        }
        found = .worktree(worktreeId: worktreeId, relativePath: self.relativeToWorkspace(path), isDirectory: false)
      }
      switch found {
      case .worktree(let id, let relative, false):
        self.navigationController?.pushViewController(
          FilePreviewViewController(session: self.session, worktreeId: id, path: relative), animated: true)
      case .worktree(let id, _, true):
        self.navigationController?.pushViewController(
          FileExplorerViewController(session: self.session, worktreeId: id), animated: true)
      case .absolute(let grant):
        self.navigationController?.pushViewController(
          FilePreviewViewController(session: self.session, worktreeId: worktreeId, path: grant.absolutePath, artifact: grant),
          animated: true)
      case nil:
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        self.sayOnce(title: String(localized: "files.filePreviewResponse.fileNotFound", defaultValue: "File not found"), message: path)
      }
    }
  }

  /// An alert, unless one is already up.
  private func sayOnce(title: String, message: String) {
    guard presentedViewController == nil else { return }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
    present(alert, animated: true)
  }

  private func relativeToWorkspace(_ path: String) -> String {
    guard let root = session.worktree(id: worktreeId)?.path, !root.isEmpty, path.hasPrefix(root) else { return path }
    return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private func openSourceControl() {
    navigationController?.pushViewController(SourceControlViewController(session: session, worktreeId: worktreeId), animated: true)
  }

  private func openFiles() {
    navigationController?.pushViewController(FileExplorerViewController(session: session, worktreeId: worktreeId), animated: true)
  }

  /// Past agent sessions here; one with a chat opens it in this workspace.
  private func openHistory() {
    let history = AgentHistoryViewController(session: session, worktreeId: worktreeId)
    let session = session
    history.onOpenChat = { [weak self] worktreeId, sessionId in
      guard let self else { return }
      if worktreeId == self.worktreeId {
        self.focusSessionId = sessionId
        self.navigationController?.popToViewController(self, animated: true)
        self.apply(self.tabs)
      } else {
        self.navigationController?.pushViewController(
          SessionViewController(session: session, worktreeId: worktreeId, sessionId: sessionId), animated: true)
      }
    }
    navigationController?.pushViewController(history, animated: true)
  }

  /// A bot's items; an item's chat opens here, in its home.
  private func openItems() {
    guard let bot else { return }
    let items = BotItemsViewController(session: session, botId: bot.id)
    items.onOpenChat = { [weak self] sessionId in
      guard let self else { return }
      self.focusSessionId = sessionId
      self.navigationController?.popToViewController(self, animated: true)
      self.apply(self.tabs)
    }
    navigationController?.pushViewController(items, animated: true)
  }

  /// A terminal, a chat with an agent, a browser or a note.
  private func newTabMenu() -> UIMenu {
    let api = session.api
    let selector = selector
    return UIMenu(
      title: String(localized: "session.tabStrip.newTab", defaultValue: "New tab"),
      children: [
        UIAction(
          title: String(localized: "session.header.terminalTitle", defaultValue: "Terminal"),
          image: Lucide.squareTerminal.image(size: 18)
        ) { [weak self] _ in self?.run { try await api.createTerminalTab(worktree: selector) } },
        UIAction(title: "Claude", image: AgentMark.claude.image(size: 18)) { [weak self] _ in
          self?.run { try await api.createChat(agent: "claude", worktree: selector) }
        },
        UIAction(title: "Codex", image: AgentMark.codex.image(size: 18)) { [weak self] _ in
          self?.run { try await api.createChat(agent: "codex", worktree: selector) }
        },
        UIMenu(
          options: .displayInline,
          children: [
            UIAction(
              title: String(localized: "session.sheets.browser", defaultValue: "Browser"), image: Lucide.globe.image(size: 18)
            ) { [weak self] _ in self?.promptNewBrowser() },
            browserProfileMenu(),
            UIAction(
              title: String(localized: "session.sheets.markdownNote", defaultValue: "Markdown Note"),
              image: Lucide.fileText.image(size: 18)
            ) { [weak self] _ in self?.run { try await api.createMarkdownNote(worktree: selector) } },
          ]),
      ])
  }

  /// The new-tab sheet's Profile row (MobileBrowserProfilePicker.tsx): which of the host's browser profiles a
  /// new browser tab opens in, read when the menu opens. Hidden with one profile, or on a host that lists none.
  private func browserProfileMenu() -> UIMenuElement {
    let api = session.api
    let streams = session.status?.supports(BrowserCapability.screencast) == true
    return UIDeferredMenuElement.uncached { [weak self] completion in
      guard streams else { return completion([]) }
      Task { @MainActor in
        let profiles = await api.browserProfiles()
        guard let self, profiles.count >= 2 else { return completion([]) }
        let defaultLabel = String(localized: "session.browserProfile.default", defaultValue: "Default")
        let workspaceDefault = String(localized: "session.browserProfile.workspaceDefault", defaultValue: "Workspace default")
        // A profile deleted on the host since it was picked falls back to the workspace default.
        if let chosen = self.browserProfileId, !profiles.contains(where: { $0.id == chosen }) { self.browserProfileId = nil }
        let chosen = self.browserProfileId
        let options: [(id: String?, title: String)] =
          [(nil, workspaceDefault)] + profiles.map { ($0.id, BrowserProfile.label($0.label, id: $0.id, defaultLabel: defaultLabel)) }
        let menu = UIMenu(
          title: String(localized: "session.browserProfile.title", defaultValue: "Profile"),
          subtitle: options.first { $0.id == chosen }?.title,
          image: Lucide.userRound.image(size: 18),
          children: options.map { option in
            UIAction(title: option.title, state: option.id == chosen ? .on : .off) { [weak self] _ in
              self?.browserProfileId = option.id
            }
          })
        completion([menu])
      }
    }
  }

  /// The official New Browser prompt: a URL, or blank for a new tab. Hosts that can't stream a page to the
  /// phone don't get one opened from it.
  private func promptNewBrowser() {
    guard session.status?.supports(BrowserCapability.screencast) == true else {
      Toast.shared.show(
        String(localized: "session.sheets.browserStreamingUnavailable", defaultValue: "This host can't stream browser tabs"),
        kind: .error)
      return
    }
    let alert = UIAlertController(
      title: String(localized: "session.sheets.newBrowser", defaultValue: "New Browser"),
      message: String(localized: "session.sheets.urlPrompt", defaultValue: "Enter a URL, or leave blank for a new tab."),
      preferredStyle: .alert)
    alert.addTextField { field in
      field.placeholder = "https://example.com"
      field.keyboardType = .URL
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
      field.returnKeyType = .go
    }
    alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
    let api = session.api
    let selector = selector
    let open = UIAlertAction(title: String(localized: "common.open", defaultValue: "Open"), style: .default) { [weak self, weak alert] _ in
      guard let url = BrowserURL.normalize(alert?.textFields?.first?.text ?? "") else {
        Toast.shared.show(
          String(localized: "session.useContentCreateActions.invalidUrl", defaultValue: "Enter a valid URL"), kind: .error)
        return
      }
      let profileId = self?.browserProfileId
      self?.run { try await api.createBrowserTab(worktree: selector, url: url, profileId: profileId) }
    }
    alert.addAction(open)
    alert.preferredAction = open
    present(alert, animated: true)
  }

  private static func icon(for tab: SessionTab) -> UIImage? {
    switch tab.kind {
    case .agentSession(_, let agent): return AgentMark.icon(for: agent)?.image(size: 18)
    case .browser: return Lucide.globe.image(size: 18)
    case .file, .markdown: return Lucide.fileText.image(size: 18)
    default: return Lucide.squareTerminal.image(size: 18)
    }
  }

  /// A tab write; the tabs subscription shows its result, and a refusal is said.
  private func run(_ write: @escaping () async throws -> Void) {
    Task {
      do {
        try await write()
      } catch {
        let message = (error as? RPCError)?.message ?? error.localizedDescription
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
        present(alert, animated: true)
      }
    }
  }

  // While this workspace is on screen, its own pushes don't alert (Settings › Notifications › Suppress while
  // focused).
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    workspaceVisible = true
    updateNavigationAppearance()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    PushCenter.viewing = (hostKey: session.host.id.uuidString, worktreeId: worktreeId, executionHost: nil)
    PiPCenter.shared.attachTranscript(to: view) { [weak self] in self?.pipFrame() }
  }

  /// The tab on screen as a picture-in-picture frame.
  private func pipFrame() -> PiPFrame? {
    let worktree = session.worktree(id: worktreeId)
    let name = bot?.name ?? worktree?.displayName ?? ""
    let workspaceWorking = worktree?.displayStatus == "working"
    let word = { (working: Bool) in
      working
        ? String(localized: "sidebar.cardSlot.working", defaultValue: "Working")
        : String(localized: "bots.row.idle", defaultValue: "Idle")
    }
    if let chat = current as? ChatViewController {
      let tail = chat.pipLines()
      // A terminal's transcript can lag behind the workspace's live agent status.
      let working = tail.working || (chat.model.isTerminalChat && workspaceWorking)
      return PiPFrame(title: name, status: word(working), working: working, lines: tail.lines, terminal: false)
    }
    if let terminal = current as? TerminalTabController {
      return PiPFrame(
        title: name, status: word(workspaceWorking), working: workspaceWorking,
        lines: terminal.pipLines().map { ($0, .terminal) }, terminal: true)
    }
    return nil
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    workspaceVisible = false
    updateNavigationAppearance()
    if PushCenter.viewing?.worktreeId == worktreeId { PushCenter.viewing = nil }
    PiPCenter.shared.detachTranscript(from: view)
  }

  /// Text size for what is on screen: the terminal's font in a terminal tab, the chat's text otherwise.
  private func openTextSize() {
    guard current is TerminalTabController else {
      present(ChatTextSettingsController.sheet(), animated: true)
      return
    }
    let navigation = UINavigationController(rootViewController: TerminalSettingsViewController())
    navigation.topViewController?.title = String(localized: "session.textSizeSheet.terminalTitle", defaultValue: "Terminal text")
    navigation.topViewController?.navigationItem.rightBarButtonItem = UIBarButtonItem(
      systemItem: .done, primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) })
    if let sheet = navigation.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    present(navigation, animated: true)
  }

  private func moreMenu() -> UIMenu {
    UIMenu(children: [
      PiPCenter.shared.isSupported
        ? UIMenu(
          title: String(localized: "orcaios.pip.start", defaultValue: "Picture in Picture"),
          image: UIImage(systemName: "pip"),
          children: [
            UIAction(
              title: String(localized: "orcaios.pip.open", defaultValue: "Open now"), image: UIImage(systemName: "pip.enter")
            ) { _ in PiPCenter.shared.start() },
            UIAction(
              title: String(localized: "orcaios.pip.onLeave", defaultValue: "Picture in Picture on leaving"),
              image: UIImage(systemName: "rectangle.on.rectangle"), state: PiPCenter.startsOnLeave ? .on : .off
            ) { _ in PiPCenter.startsOnLeave.toggle() },
            UIAction(
              title: String(localized: "orcaios.pip.compact", defaultValue: "Mini status bar"),
              image: UIImage(systemName: "rectangle.compress.vertical"), state: PiPCenter.usesCompactLayout ? .on : .off
            ) { _ in PiPCenter.usesCompactLayout.toggle() },
            UIAction(
              title: String(localized: "orcaios.pip.commands", defaultValue: "Show each command in Picture in Picture"),
              image: UIImage(systemName: "list.bullet.rectangle"), attributes: PiPCenter.usesCompactLayout ? .hidden : [],
              state: PiPCenter.showsCommands ? .on : .off
            ) { _ in PiPCenter.showsCommands.toggle() },
          ]) : UIMenu(options: .displayInline, children: []),
      UIAction(
        title: String(localized: "session.header.fileExplorer", defaultValue: "File explorer"),
        image: Lucide.folderTree.image(size: 18)) { [weak self] _ in self?.openFiles() },
      UIAction(
        title: String(localized: "session.headerMoreActionsSheet.agentHistory", defaultValue: "Agent History"),
        image: Lucide.history.image(size: 18)) { [weak self] _ in self?.openHistory() },
      UIAction(
        title: String(localized: "session.header.textSize", defaultValue: "Text size"),
        image: Lucide.aLargeSmall.image(size: 18)) { [weak self] _ in self?.openTextSize() },
    ])
  }
}

/// A terminal tab before its terminal exists: a spinner and a word, replaced as soon as the handle arrives.
private final class PendingTerminalViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgBase
    let spinner = UIActivityIndicatorView(style: .medium)
    spinner.startAnimating()
    let label = TextLabel(
      String(localized: "orcaios.session.terminalStarting", defaultValue: "Starting terminal…"), size: 15,
      color: Palette.textMuted, alignment: .center, lines: 0)
    let stack = UIStackView(arrangedSubviews: [spinner, label])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = Spacing.sm
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -Spacing.xl * 2),
    ])
  }
}

/// A tab this client cannot open yet.
private final class UnsupportedTabViewController: UIViewController {
  private let sessionTab: SessionTab?

  init(tab: SessionTab?) {
    sessionTab = tab
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgBase
    let label = TextLabel(
      sessionTab == nil
        ? String(localized: "session.openingWorkspace", defaultValue: "Opening workspace")
        : String(localized: "orcaios.session.tabUnsupported", defaultValue: "This tab can't be opened on the phone yet"),
      size: Typography.bodySize, color: Palette.textSecondary, alignment: .center, lines: 0)
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Spacing.xl),
    ])
  }
}

/// A bot home's title: its face beside its name, then its state under them (MobileSessionTitleBlock.tsx).
private final class BotTitleView: UIView {
  private let avatar = BotAvatarView(size: 20)
  private let name = TextLabel(size: 17, weight: .semibold)
  private let status = UILabel()

  init() {
    super.init(frame: .zero)
    let top = UIStackView(arrangedSubviews: [avatar, name])
    top.spacing = 6
    top.alignment = .center
    let column = UIStackView(arrangedSubviews: [top, status])
    column.axis = .vertical
    column.alignment = .center
    column.spacing = 1
    column.translatesAutoresizingMaskIntoConstraints = false
    addSubview(column)
    column.pin(to: self)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(bot: Bot, status word: String, dot: UIColor) {
    avatar.show(bot)
    name.text = bot.name
    let line = NSMutableAttributedString(
      string: "●  ", attributes: [.foregroundColor: dot, .font: UIFont.systemFont(ofSize: 11)])
    line.append(NSAttributedString(string: word, attributes: [.foregroundColor: Palette.textSecondary, .font: UIFont.systemFont(ofSize: 13)]))
    status.attributedText = line
    accessibilityLabel = "\(bot.name), \(word)"
    isAccessibilityElement = true
  }
}

/// A workspace with no tabs (MobileSessionContentState.tsx): says so, and makes one.
private final class NoTabsViewController: UIViewController {
  private let onCreate: () -> Void

  init(onCreate: @escaping () -> Void) {
    self.onCreate = onCreate
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgBase
    let icon = LucideView(.squareTerminal, size: 34, strokeWidth: 1.6, color: Palette.textMuted)
    let title = TextLabel(
      String(localized: "session.activeContent.noTabs", defaultValue: "No tabs in this session"), size: 17,
      weight: .semibold, alignment: .center)
    var configuration = UIButton.Configuration.prominentGlass()
    configuration.title = String(localized: "session.activeContent.createTab", defaultValue: "Create Tab")
    configuration.baseBackgroundColor = Palette.accentBlue
    let create = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onCreate() })
    let stack = UIStackView(arrangedSubviews: [icon, title, create])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = Spacing.md
    stack.setCustomSpacing(Spacing.lg, after: title)
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
  }
}


/// Calls back when a sheet is swiped away.
final class SheetCloser: NSObject, UIAdaptivePresentationControllerDelegate {
  private let closed: () -> Void
  init(_ closed: @escaping () -> Void) { self.closed = closed }
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { closed() }
}
