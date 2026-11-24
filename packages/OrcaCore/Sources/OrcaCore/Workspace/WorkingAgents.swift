import Foundation

/// A pane and the active agents it owns, for the status-only picture-in-picture display.
public struct WorkingAgent: Equatable, Sendable, Identifiable {
  public enum Activity: Hashable, Sendable {
    case working
    case needsDecision
    case needsAnswer

    /// Lower ranks surface first: blocking decisions > async questions > active work.
    public var priority: Int {
      switch self {
      case .needsDecision: 0
      case .needsAnswer: 1
      case .working: 2
      }
    }
  }

  public struct ID: Hashable, Sendable {
    public let host: UUID
    public let pane: String
  }

  public struct Child: Equatable, Sendable {
    public let agentType: String?
    /// Provider children sometimes report a role name in agentType, such as "explorer".
    public let owningAgentType: String?
    public let activity: Activity
  }

  public let id: ID
  public let worktreeId: String
  public let workspace: String
  public let name: String?
  public let agentType: String?
  public let isWorker: Bool
  public let leadActivity: Activity?
  public let structuredSessionId: String?
  public let updatedAt: Double?
  public let children: [Child]

  public var activity: Activity {
    if leadActivity == .needsDecision || children.contains(where: { $0.activity == .needsDecision }) {
      return .needsDecision
    }
    if leadActivity == .needsAnswer || children.contains(where: { $0.activity == .needsAnswer }) {
      return .needsAnswer
    }
    return .working
  }

  private struct Pane: Sendable {
    let agent: Worktree.Agent
    let worktreeId: String
    let workspace: String

    var parent: String? { agent.parentPaneKey ?? agent.listParentPaneKey }
    var leadActivity: Activity? { WorkingAgent.activity(of: agent) }

    var providerChildren: [Child] {
      var seen = Set<String>()
      return agent.children.sorted(by: { $0.id < $1.id }).compactMap { child in
        // Child work uses blocked for a failure. Waiting is the explicit request for a person.
        guard child.state == "working" || child.state == "waiting", seen.insert(child.id).inserted else { return nil }
        return Child(agentType: child.agentType, owningAgentType: agent.agentType,
          activity: child.state == "waiting" ? .needsDecision : .working)
      }
    }

    var latestActiveTimestamp: Double? {
      let childTimes = agent.children
        .filter { $0.state == "working" || $0.state == "waiting" }
        .compactMap(\.updatedAt)
      return ([agent.updatedAt].compactMap { $0 } + childTimes).filter { $0 > 0 }.max()
    }
  }

  public static func inCatalog(_ worktrees: [Worktree], host: UUID) -> [Self] {
    let panes = worktrees.filter { !$0.isArchived }.sorted(by: { $0.id < $1.id }).flatMap { worktree in
      // A nameless workspace can keep its path private on an overlay.
      let workspace = worktree.displayName.isEmpty ? worktree.repo : worktree.displayName
      return worktree.agents.filter { !$0.restoredUnconfirmed }.sorted(by: { $0.paneKey < $1.paneKey })
        .map { Pane(agent: $0, worktreeId: worktree.id, workspace: workspace) }
    }
    let groups = LineageBranch.build(panes, id: \.agent.paneKey, parent: \.parent)
    func descendants(_ branch: LineageBranch<Pane>) -> [Child] {
      branch.children.flatMap { child in
        let pane = child.entry
        var agents: [Child] = []
        if let activity = pane.leadActivity {
          agents.append(Child(agentType: pane.agent.agentType, owningAgentType: nil, activity: activity))
        }
        return agents + pane.providerChildren + descendants(child)
      }
    }
    func latestTimestamp(_ branch: LineageBranch<Pane>) -> Double? {
      let own = branch.entry.latestActiveTimestamp
      let nested = branch.children.compactMap(latestTimestamp)
      return ([own].compactMap { $0 } + nested).max()
    }
    return groups.compactMap { group in
      let pane = group.entry
      let agent = pane.agent
      let children = pane.providerChildren + descendants(group)
      let leadActivity = pane.leadActivity
      guard leadActivity != nil || !children.isEmpty else { return nil }
      return Self(id: ID(host: host, pane: agent.paneKey), worktreeId: pane.worktreeId, workspace: pane.workspace,
        name: agent.displayName.flatMap { $0.isEmpty ? nil : $0 }, agentType: agent.agentType,
        isWorker: pane.parent != nil, leadActivity: leadActivity,
        structuredSessionId: agent.structuredSessionId,
        updatedAt: agent.updatedAt.flatMap { $0 > 0 ? $0 : nil } ?? latestTimestamp(group),
        children: children)
    }
  }

  /// Returns normalized titles that appear on two or more distinct hosts across the active roster,
  /// so compact status displays can show a host subtitle only when disambiguation is needed.
  public static func crossHostDuplicateTitles(in items: [(host: UUID, title: String)]) -> Set<String> {
    var hostsByTitle: [String: Set<UUID>] = [:]
    for item in items {
      let key = normalizedTitleKey(item.title)
      guard !key.isEmpty else { continue }
      hostsByTitle[key, default: []].insert(item.host)
    }
    return Set(hostsByTitle.compactMap { $0.value.count > 1 ? $0.key : nil })
  }

  public static func normalizedTitleKey(_ title: String) -> String {
    title.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
  }

  private static func activity(of agent: Worktree.Agent) -> Activity? {
    guard agent.listState != "unconfirmed", agent.listState != "unverifiable" else { return nil }
    switch agent.mainState ?? agent.listState ?? agent.state {
    case "waiting":
      // The structured host uses the lead's waiting state for questions, including async ones.
      return agent.structuredSessionId != nil && agent.mainState == "waiting" ? .needsAnswer : .needsDecision
    case "blocked", "permission": return .needsDecision
    default: return agent.isActivelyWorking ? .working : nil
    }
  }
}

/// Advances one line at a time and gives a changed pair a full interval to read.
/// - Single pinned attention (`pinned`): row 1 stays fixed while row 2 rotates through the remaining agents.
/// - Split zone (`splitAt` in `2..<count`): row 1 rotates through the leading attention slice (`0..<splitAt`)
///   while row 2 rotates independently through the trailing working slice (`splitAt..<count`).
public struct WorkingAgentRotation {
  public struct Page: Equatable {
    public let indices: [Int]
    public let nextIndex: Int?
    public let secondaryNextIndex: Int?
    public let didAdvance: Bool
    public let stepDirection: Int
    public let scrollsOnlySecondRow: Bool
    public let splitAt: Int?

    public init(
      indices: [Int], nextIndex: Int?, secondaryNextIndex: Int? = nil,
      didAdvance: Bool, stepDirection: Int? = nil, scrollsOnlySecondRow: Bool = false, splitAt: Int? = nil
    ) {
      self.indices = indices
      self.nextIndex = nextIndex
      self.secondaryNextIndex = secondaryNextIndex
      self.didAdvance = didAdvance
      self.stepDirection = stepDirection ?? (didAdvance ? 1 : 0)
      self.scrollsOnlySecondRow = scrollsOnlySecondRow
      self.splitAt = splitAt
    }
  }

  private var visible: [WorkingAgent.ID] = []
  private var shownAt: TimeInterval = 0
  private var lastStart = 0
  private var lastTopStart = 0
  private var lastBottomStart = 0
  private static let pageSize = 2
  private static let interval: TimeInterval = 3

  public init() {}

  public mutating func page(
    in agents: [WorkingAgent.ID], at time: TimeInterval, rotating: Bool,
    preferring priority: WorkingAgent.ID? = nil, pinned: WorkingAgent.ID? = nil,
    splitAt: Int? = nil, step: Int = 0
  ) -> Page {
    guard agents.count > Self.pageSize else {
      visible = agents
      shownAt = time
      lastStart = 0
      lastTopStart = 0
      lastBottomStart = 0
      return Page(indices: Array(agents.indices), nextIndex: nil, didAdvance: false)
    }

    let manualStep = step > 0 ? 1 : (step < 0 ? -1 : 0)

    if let pinned, let pinnedIndex = agents.firstIndex(of: pinned) {
      let others = agents.indices.filter { $0 != pinnedIndex }
      let otherCount = others.count
      let previousSecond = visible.count >= 2 && visible[0] == pinned ? visible[1] : visible.first { $0 != pinned }
      let anchorSlot = previousSecond.flatMap { id in others.firstIndex { agents[$0] == id } }
        ?? min(lastBottomStart, otherCount - 1)
      let current = [agents[pinnedIndex], agents[others[anchorSlot]]]
      let samePair = visible == current
      let autoAdvance = manualStep == 0 && rotating && samePair && time - shownAt >= Self.interval
      let delta = manualStep != 0 ? manualStep : (autoAdvance ? 1 : 0)
      let slot = (anchorSlot + delta + otherCount) % otherCount
      let secondIndex = others[slot]
      let nextIndex = others[(slot + 1) % otherCount]
      if delta != 0 || !rotating || !samePair { shownAt = time }
      visible = [agents[pinnedIndex], agents[secondIndex]]
      lastStart = slot
      lastBottomStart = slot
      return Page(
        indices: [pinnedIndex, secondIndex], nextIndex: nextIndex,
        didAdvance: delta != 0, stepDirection: delta, scrollsOnlySecondRow: true)
    }

    if let splitAt, splitAt >= 2, splitAt < agents.count {
      let topCount = splitAt
      let bottomIndices = Array(splitAt..<agents.count)
      let bottomCount = bottomIndices.count
      let preferredTop = priority.flatMap { id -> Int? in
        guard let idx = agents.firstIndex(of: id), idx < splitAt else { return nil }
        return idx
      }
      let previousTop = visible.first.flatMap { id -> Int? in
        guard let idx = agents.firstIndex(of: id), idx < splitAt else { return nil }
        return idx
      }
      let topAnchor = preferredTop ?? previousTop ?? min(lastTopStart, topCount - 1)
      let previousBottom = (visible.count >= 2 ? [visible[1], visible[0]] : visible)
        .compactMap { id in bottomIndices.firstIndex { agents[$0] == id } }
        .first
      let bottomAnchor = previousBottom ?? min(lastBottomStart, bottomCount - 1)
      let current = [agents[topAnchor], agents[bottomIndices[bottomAnchor]]]
      let samePair = visible == current
      let autoAdvance = manualStep == 0 && preferredTop == nil && rotating && samePair && time - shownAt >= Self.interval
      let delta = preferredTop == nil ? (manualStep != 0 ? manualStep : (autoAdvance ? 1 : 0)) : 0
      let topSlot = (topAnchor + delta + topCount) % topCount
      let bottomSlot = (delta != 0 && bottomCount > 1) ? (bottomAnchor + delta + bottomCount) % bottomCount : bottomAnchor
      let firstIndex = topSlot
      let secondIndex = bottomIndices[bottomSlot]
      let nextTop = (topSlot + 1) % topCount
      let nextBottom = bottomCount > 1 ? bottomIndices[(bottomSlot + 1) % bottomCount] : nil
      if preferredTop != nil || delta != 0 || !rotating || !samePair { shownAt = time }
      visible = [agents[firstIndex], agents[secondIndex]]
      lastStart = firstIndex
      lastTopStart = topSlot
      lastBottomStart = bottomSlot
      return Page(
        indices: [firstIndex, secondIndex], nextIndex: nextTop, secondaryNextIndex: nextBottom,
        didAdvance: delta != 0, stepDirection: delta, scrollsOnlySecondRow: false, splitAt: splitAt)
    }

    let count = agents.count
    let preferred = priority.flatMap { agents.firstIndex(of: $0) }
    let anchor = preferred ?? visible.lazy.compactMap { agents.firstIndex(of: $0) }.first ?? min(lastStart, count - 1)
    let current = [agents[anchor], agents[(anchor + 1) % count]]
    let samePair = visible == current
    let autoAdvance = manualStep == 0 && preferred == nil && rotating && samePair && time - shownAt >= Self.interval
    let delta = preferred == nil ? (manualStep != 0 ? manualStep : (autoAdvance ? 1 : 0)) : 0
    let start = (anchor + delta + count) % count
    let indices = [start, (start + 1) % count]
    if preferred != nil || delta != 0 || !rotating || !samePair { shownAt = time }
    visible = indices.map { agents[$0] }
    lastStart = start
    return Page(
      indices: indices, nextIndex: (start + Self.pageSize) % count,
      didAdvance: delta != 0, stepDirection: delta)
  }
}
