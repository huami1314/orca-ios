import Foundation

/// A read-only view of a structured session. Keep journal identities and counts in memory, without message text.
public struct AgentActivityMetrics: Sendable {
  public struct Reading: Sendable, Equatable {
    public let totalTokens: Int?
    public let tokenCountIsPartial: Bool
    public let toolCalls: Int?
    public let toolCountIsPartial: Bool
    public let toolIsRunning: Bool
    public let activeToolKind: TranscriptItem.ToolCall.ActivityKind?
    public let latestWebSearchCallID: String?
    public let webSearchIsRunning: Bool
    public let turnStartedAt: Double?
  }

  private struct Call: Sendable {
    let id: String
    var running: Bool
    let standalone: Bool
    var kind: TranscriptItem.ToolCall.ActivityKind
    var isWebSearch: Bool

    init(_ json: JSONValue, fallbackID: String, standalone: Bool) {
      id = json["callId"]?.stringValue ?? fallbackID
      running = json["state"]?.stringValue == "running"
      self.standalone = standalone
      let name = json["name"]?.stringValue ?? ""
      let command = json["input"]?["command"]?.stringValue
      let hasWebResults = json["webSearchResults"].map { $0 != .null } ?? false
      kind = TranscriptItem.ToolCall.activityKind(name: name, command: command, hasWebSearchResults: hasWebResults)
      isWebSearch = kind == .webSearch
    }
  }

  private struct TokenCount: Sendable {
    let agentId: String
    let total: Int

    init?(id: String?, total: JSONValue?) {
      guard let id, !id.isEmpty, let count = total?.intValue, count >= 0 else { return nil }
      agentId = id
      self.total = count
    }

    init?(_ entry: JSONValue?) {
      self.init(id: entry?["id"]?.stringValue, total: entry?["tokens"])
    }
  }

  private struct Row: Sendable {
    let id: String
    let revision: Int
    let sequence: Int
    let agentId: String?
    let turnId: String?
    let turnRunning: Bool?
    let turnStartedAt: Double?
    let calls: [Call]
    let results: [String]
    let subagentUsage: [TokenCount]

    init?(_ item: JSONValue) {
      guard let id = item["itemId"]?.stringValue, let body = item["body"],
        let revision = item["revision"]?.intValue, let sequence = item["sequence"]?.intValue
      else { return nil }
      self.id = id
      self.revision = revision
      self.sequence = sequence
      agentId = item["agentId"]?.stringValue
      turnId = item["turnScope"]?["turnItemId"]?.stringValue
      let kind = body["kind"]?.stringValue
      let blocks = body["blocks"]?.arrayValue ?? []
      turnRunning = kind == "turn" ? body["state"]?.stringValue.map { $0 == "running" } : nil
      if kind == "turn" {
        let candidate = body["startedAt"]?.doubleValue ?? item["observedAt"]?.doubleValue
        turnStartedAt = candidate.flatMap { $0 > 0 ? $0 : nil }
      } else {
        turnStartedAt = nil
      }
      if kind == "tool-call" {
        calls = [Call(body, fallbackID: "row:\(id)", standalone: true)]
      } else {
        calls = blocks.enumerated().compactMap { index, block in
          guard block["type"]?.stringValue == "tool-call" else { return nil }
          return Call(block, fallbackID: "row:\(id):\(index)", standalone: false)
        }
      }
      results = blocks.compactMap { $0["type"]?.stringValue == "tool-result" ? $0["callId"]?.stringValue : nil }
      subagentUsage = blocks.flatMap { block -> [TokenCount] in
        switch block["type"]?.stringValue {
        case "subagent": return [TokenCount(block)].compactMap { $0 }
        case "subagent-group": return (block["agents"]?.arrayValue ?? []).compactMap { TokenCount($0) }
        default: return []
        }
      }
    }
  }

  private struct Turn: Sendable {
    let id: String
    let running: Bool
    let startedAt: Double?
  }

  private var cursor: TranscriptCursor?
  private var turn: Turn?
  private var rows: [String: Row] = [:]
  private var subagentTokens: [String: Int] = [:]
  private var hasOlder = true
  private var catchingUp = false

  public init() {}

  public mutating func apply(_ frame: JSONValue) {
    switch frame["type"]?.stringValue {
    case "snapshot", "reset":
      self = Self()
      guard let page = frame["page"] else { return }
      cursor = TranscriptCursor(page["liveCursor"]) ?? TranscriptCursor(page["window"]?["nextCursor"])
      hasOlder = page["hasOlder"]?.boolValue != false
      catchingUp = page["hasNewer"]?.boolValue == true
      for record in page["subagentRoster"]?.arrayValue ?? [] {
        recordTokenCount(TokenCount(record["entry"]))
      }
      observeBackgroundTokenCounts(frame["backgroundTasks"] ?? page["backgroundTasks"])
      for row in (page["items"]?.arrayValue ?? []).compactMap(Row.init) { store(row) }
      noteTurn(frame["latestTurn"] ?? page["latestTurn"])
    case "batch":
      guard let batch = frame["batch"], let next = TranscriptCursor(batch["cursor"]) else { return }
      if cursor?.epoch != next.epoch { self = Self() }
      if let cursor, next.sequence < cursor.sequence { return }
      cursor = next
      catchingUp = frame["hasNewer"]?.boolValue == true
      observeBackgroundTokenCounts(frame["backgroundTasks"])
      for row in (batch["items"]?.arrayValue ?? []).compactMap(Row.init) {
        if let old = rows[row.id], old.revision >= row.revision { continue }
        store(row)
      }
      for id in (batch["removedItemIds"]?.arrayValue ?? []).compactMap(\.stringValue) { rows.removeValue(forKey: id) }
      noteTurn(frame["latestTurn"])
    case "end": self = Self()
    default: break
    }
  }

  private mutating func store(_ row: Row) {
    rows[row.id] = row
    for entry in row.subagentUsage { recordTokenCount(entry) }
  }

  private mutating func observeBackgroundTokenCounts(_ background: JSONValue?) {
    for child in background?["children"]?.arrayValue ?? [] where child["kind"]?.stringValue == "agent" {
      recordTokenCount(TokenCount(id: child["providerId"]?.stringValue, total: child["totalTokens"]))
    }
    for key in ["tasks", "settledTasks"] {
      for task in background?[key]?.arrayValue ?? [] where task["kind"]?.stringValue == "agent" {
        guard let id = task["id"]?.stringValue else { continue }
        // Legacy Codex background-task rows prefix the thread ID used by the journal.
        let prefix = "codex-agent:"
        let providerId = id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
        recordTokenCount(TokenCount(id: providerId, total: task["totalTokens"]))
      }
    }
  }

  private mutating func recordTokenCount(_ count: TokenCount?) {
    guard let count else { return }
    subagentTokens[count.agentId] = max(subagentTokens[count.agentId] ?? count.total, count.total)
  }

  private mutating func noteTurn(_ marker: JSONValue?) {
    let previous = turn?.id
    let previousStartedAt = turn?.startedAt
    if let marker {
      turn = marker["itemId"]?.stringValue.map { id in
        let markerStart = marker["turn"]?["startedAt"]?.doubleValue.flatMap { $0 > 0 ? $0 : nil }
        let rowStart = rows[id]?.turnStartedAt
        let keptStart = previous == id ? previousStartedAt : nil
        return Turn(id: id, running: marker["turn"]?["state"]?.stringValue == "running",
          startedAt: markerStart ?? rowStart ?? keptStart)
      }
    } else if let latest = rows.values.filter({ $0.agentId == nil && $0.turnRunning != nil })
      .max(by: { $0.sequence < $1.sequence }) {
      if turn.flatMap({ rows[$0.id] != nil }) != false {
        let keptStart = previous == latest.id ? previousStartedAt : nil
        turn = Turn(id: latest.id, running: latest.turnRunning == true,
          startedAt: latest.turnStartedAt ?? keptStart)
      }
    }
    if let id = turn?.id, previous != id {
      rows = rows.filter { $0.value.turnId == nil || $0.value.turnId == id }
    }
  }

  public func reading(agentId: String?, includeChildTokenFloor: Bool = false) -> Reading {
    guard cursor != nil, !catchingUp else {
      return Reading(
        totalTokens: nil, tokenCountIsPartial: false, toolCalls: nil, toolCountIsPartial: false, toolIsRunning: false,
        activeToolKind: nil, latestWebSearchCallID: nil, webSearchIsRunning: false, turnStartedAt: nil)
    }
    let turnId = turn?.id
    let agentRows = rows.values.filter { $0.agentId == agentId }
    let relevant = agentRows.filter { turnId != nil && $0.turnId == turnId }
    let calls = resolvedCalls(in: relevant)
    let running = (turn?.running == true || agentId != nil) && calls.values.contains(where: \.running)
    let canCount = turnId != nil && (agentId == nil ? turn?.running == true : !relevant.isEmpty)
    let activeToolKind: TranscriptItem.ToolCall.ActivityKind? = canCount && running
      ? relevant.filter { $0.calls.contains { calls[$0.id]?.running == true } }
        .max { $0.sequence < $1.sequence }?
        .calls.last { calls[$0.id]?.running == true }
        .flatMap { calls[$0.id]?.kind }
      : nil
    let webSearches = calls.filter { $0.value.isWebSearch }
    let latestSearch = canCount && !webSearches.isEmpty
      ? relevant.filter { $0.calls.contains { webSearches[$0.id] != nil } }.max { $0.sequence < $1.sequence }?
        .calls.last { webSearches[$0.id] != nil }
      : nil
    let start = turnId.flatMap { rows[$0]?.sequence }
    let unscoped = agentRows.contains { row in
      row.turnId == nil && !row.calls.isEmpty && row.sequence >= (start ?? 0)
    }
    let partial = canCount && ((hasOlder && start == nil) || unscoped)
    // Providers can report the same child through several identities. The maximum
    // observed child total is a lower bound for the group even when aliases overlap.
    let floor = includeChildTokenFloor && agentId == nil ? subagentTokens.values.max() : nil
    return Reading(
      // Mobile frames publish provider totals for child agents. A root's context-window reading is separate.
      totalTokens: agentId.flatMap { subagentTokens[$0] } ?? floor,
      tokenCountIsPartial: floor != nil,
      toolCalls: canCount && (!partial || !calls.isEmpty) ? calls.count : nil,
      toolCountIsPartial: partial,
      toolIsRunning: running,
      activeToolKind: activeToolKind,
      latestWebSearchCallID: latestSearch?.id,
      webSearchIsRunning: running && webSearches.values.contains(where: \.running),
      turnStartedAt: canCount ? (turn?.startedAt ?? turnId.flatMap { rows[$0]?.turnStartedAt }) : nil)
  }

  private func resolvedCalls(in rows: [Row]) -> [String: Call] {
    let results = Set(rows.flatMap(\.results))
    var calls: [String: Call] = [:]
    for var call in rows.flatMap(\.calls) {
      let old = calls[call.id]
      if let old, (old.standalone && !call.standalone || old.standalone == call.standalone && !old.running) {
        if call.isWebSearch {
          calls[call.id]?.isWebSearch = true
          calls[call.id]?.kind = .webSearch
        } else if old.kind == .other && call.kind != .other {
          calls[call.id]?.kind = call.kind
        }
        continue
      }
      call.running = call.running && !results.contains(call.id)
      let mergedWebSearch = call.isWebSearch || old?.isWebSearch == true
      call.isWebSearch = mergedWebSearch
      if mergedWebSearch {
        call.kind = .webSearch
      } else if call.kind == .other, let oldKind = old?.kind, oldKind != .other {
        call.kind = oldKind
      }
      calls[call.id] = call
    }
    return calls
  }
}
