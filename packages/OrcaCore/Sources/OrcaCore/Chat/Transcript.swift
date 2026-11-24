import Foundation

/// A position in a chat's journal. Sequence 0 is before the first row.
public struct TranscriptCursor: Sendable, Equatable {
  public var epoch: String
  public var sequence: Int

  init?(_ json: JSONValue?) {
    guard let epoch = json?["epoch"]?.stringValue, let sequence = json?["sequence"]?.intValue else {
      return nil
    }
    self.epoch = epoch
    self.sequence = sequence
  }

  public var json: JSONValue {
    ["epoch": .string(epoch), "sequence": .number(Double(sequence))]
  }
}

/// One row of a chat transcript. `body.kind` and every enum inside are open: a host may send values
/// this build has never seen, and those must degrade to something drawable, never fail the page.
public struct TranscriptItem: Sendable, Equatable, Identifiable {
  public struct ToolCall: Sendable, Equatable {
    public var name: String
    public var input: JSONValue
    public var callId: String?
    /// `running`, `completed`, `failed`.
    public var state: String
    public var output: String?
    public var outputTruncated: Bool
    public var exitCode: Int?
    public var durationMs: Double?
    /// Images the call returned to the agent (stored on the host).
    public var outputImagePaths: [String] = []

    /// A call drawn from what the client knows, for a task whose own row isn't loaded.
    public init(name: String, input: JSONValue, output: String?) {
      self.name = name
      self.input = input
      callId = nil
      state = "completed"
      self.output = output
      outputTruncated = false
    }

    init(_ json: JSONValue) {
      name = json["name"]?.stringValue ?? ""
      input = json["input"] ?? .null
      callId = json["callId"]?.stringValue
      state = json["state"]?.stringValue ?? "completed"
      output = json["output"]?["head"]?.stringValue
      outputTruncated = json["output"]?["truncated"]?.boolValue ?? false
      exitCode = json["exitCode"]?.intValue
      durationMs = json["durationMs"]?.doubleValue
      outputImagePaths = (json["outputImagePaths"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    public enum ActivityKind: String, Sendable, Equatable, Hashable {
      case command, fileChange, webSearch, browser, search, read, integration, subagent, plan, other
    }

    public static func isWebSearch(name: String) -> Bool {
      switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "webfetch", "web search", "websearch", "web_search", "web-search", "search web", "search_web":
        return true
      default:
        return false
      }
    }

    public static func activityKind(name: String, command: String? = nil, hasWebSearchResults: Bool = false) -> ActivityKind {
      if hasWebSearchResults || isWebSearch(name: name) { return .webSearch }
      let word = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if word.hasPrefix("mcp__") { return .integration }
      if ["bash", "shell", "exec", "local_shell", "exec_command", "run_command", "command"].contains(word) {
        return (command ?? "").contains("orca browser") ? .browser : .command
      }
      switch word {
      case "browser", "orca_browser": return .browser
      case "read", "read_file", "view", "list", "ls", "list_dir": return .read
      case "search", "grep", "glob", "find", "find_by_name": return .search
      case "diff", "edit", "multiedit", "write", "write_file", "edit_file", "notebookedit", "apply_patch",
        "str_replace_based_edit_tool":
        return .fileChange
      case "task", "agent", "subagent", "invoke_subagent": return .subagent
      case "todowrite", "update_plan": return .plan
      default: return .other
      }
    }

    /// The one line a collapsed tool row shows: the command, path, pattern or URL it was called with.
    public var summary: String {
      for key in ["command", "file_path", "path", "pattern", "query", "url", "description", "prompt"] {
        if let value = input[key]?.stringValue, !value.isEmpty {
          return value
        }
      }
      if let text = input.stringValue {
        return text
      }
      return ""
    }
  }

  public enum Block: Sendable, Equatable {
    case text(String, tone: String?)
    case toolCall(ToolCall)
    case toolResult(output: String, isError: Bool, callId: String?)
    /// An image by host path or by URL; exactly one is set.
    case image(path: String?, url: String?)
    case subagent(ChatSubagent)
    case subagentGroup([ChatSubagent])
    case other(type: String)

    init(_ json: JSONValue) {
      let type = json["type"]?.stringValue ?? ""
      switch type {
      case "text":
        self = .text(json["text"]?.stringValue ?? "", tone: json["tone"]?.stringValue)
      case "tool-call":
        self = .toolCall(ToolCall(json))
      case "tool-result":
        self = .toolResult(
          output: json["output"]?.stringValue ?? "", isError: json["isError"]?.boolValue ?? false,
          callId: json["callId"]?.stringValue)
      case "image-ref":
        self = .image(path: json["path"]?.stringValue, url: json["url"]?.stringValue)
      case "subagent":
        self = ChatSubagent(json).map(Block.subagent) ?? .other(type: type)
      case "subagent-group":
        self = .subagentGroup((json["agents"]?.arrayValue ?? []).compactMap(ChatSubagent.init))
      default:
        self = .other(type: type)
      }
    }
  }

  public struct Message: Sendable, Equatable {
    /// `user`, `assistant`, `tool`, `reasoning`, `system`.
    public var role: String
    public var blocks: [Block]
    /// Still being written by the agent.
    public var isStreaming: Bool
    /// A `/compact` or `/clear` the user sent.
    public var commandName: String?
    /// Who Orca delivered it for: `bot-created` is Orca's own first turn to a new bot, drawn as a notice.
    public var origin: String? = nil
    /// Orca delivers worker mail through the user role, with the original sender attached.
    public var agentSenders: [String]? = nil
    /// Mail's human-readable fields, when the host supplies their ranges in the canonical message.
    public var agentMailText: String? = nil
    /// Work the agent did with an image, not words it said: Codex viewing one, or making one
    /// (native-chat-generated-image.ts). Its image blocks are the pictures.
    public var isImageOperation = false

    public var subagents: [ChatSubagent] {
      blocks.flatMap { block -> [ChatSubagent] in
        return switch block {
        case .subagent(let agent): [agent]
        case .subagentGroup(let agents): agents
        default: []
        }
      }
    }

    public var isSubagentNotice: Bool {
      role == "system" && !subagents.isEmpty && blocks.allSatisfy { block in
        switch block {
        case .text, .subagent, .subagentGroup: true
        default: false
        }
      }
    }

    /// The message's text blocks joined, which is what copy and the bubble use.
    public var text: String {
      blocks.compactMap { block in
        if case .text(let text, _) = block {
          return text
        }
        return nil
      }.joined(separator: "\n\n")
    }

    public var imagePaths: [String] {
      blocks.compactMap { block in
        if case .image(let path, _) = block {
          return path
        }
        return nil
      }
    }
  }

  public struct PromptOption: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var description: String?
    /// `allow_once`, `allow_always`, `reject_once`, `reject_always`, when the host classifies the option.
    public var intent: String?

    init?(_ json: JSONValue) {
      guard let id = json["id"]?.stringValue else {
        return nil
      }
      self.id = id
      label = json["label"]?.stringValue ?? id
      description = json["description"]?.stringValue
      intent = json["intent"]?.stringValue
    }

    public var isRejection: Bool {
      intent?.hasPrefix("reject") ?? false
    }
  }

  /// One question of a prompt: single or multiple choice, and maybe its own words instead.
  public struct Question: Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    public var header: String?
    public var multiSelect: Bool
    public var options: [PromptOption]
    /// Present when the person may answer in their own words.
    public var freeText: FreeText?
    /// The provider takes a reply that leaves this one unanswered.
    public var skippable: Bool

    public init(
      id: String, text: String, header: String?, multiSelect: Bool, options: [PromptOption], freeText: FreeText?, skippable: Bool
    ) {
      self.id = id
      self.text = text
      self.header = header
      self.multiSelect = multiSelect
      self.options = options
      self.freeText = freeText
      self.skippable = skippable
    }

    public struct FreeText: Sendable, Equatable {
      public var placeholder: String?
      public var multiline: Bool
      public var allowEmpty: Bool
    }
  }

  /// What the person answered one question with.
  public struct Answer: Sendable, Equatable {
    public var questionId: String
    public var optionIds: [String]
    public var other: String?

    public init(questionId: String, optionIds: [String], other: String? = nil) {
      self.questionId = questionId
      self.optionIds = optionIds
      self.other = other
    }

    var json: JSONValue {
      var object: [String: JSONValue] = ["questionId": .string(questionId), "optionIds": .array(optionIds.map { .string($0) })]
      if let other { object["other"] = .string(other) }
      return .object(object)
    }
  }

  /// An approval or question card.
  public struct Prompt: Sendable, Equatable {
    public var title: String
    public var detail: String?
    public var options: [PromptOption]
    /// `pending`, `resolved`, `cancelled`.
    public var resolutionState: String
    public var selectedOptionId: String?
    /// A question's questions, structured; empty on approvals and older hosts.
    public var questions: [Question] = []
    /// What was answered, per question, once resolved.
    public var answers: [Answer] = []

    public var isPending: Bool { resolutionState == "pending" }
  }

  public struct Turn: Sendable, Equatable {
    public var turnId: String
    /// `running`, `completed`, `interrupted`, `unverifiable`.
    public var state: String
    public var startedAt: Double?
    public var durationMs: Double?
  }

  public enum Body: Sendable, Equatable {
    case message(Message)
    case toolCall(ToolCall)
    case diff(path: String, patch: String, truncated: Bool)
    case approval(Prompt)
    case question(Prompt)
    case status(text: String, tone: String?)
    case agentStarted(dispatchId: String, name: String, task: String)
    case turn(Turn)
    case other(kind: String)
  }

  public var id: String
  public var revision: Int
  public var sequence: Int
  public var sequenceIndex: Int
  /// Host clock, milliseconds.
  public var observedAt: Double
  /// Set on a subagent's row; nil for the session's own agent.
  public var agentId: String?
  public var parentAgentId: String?
  public var producerKind: String?
  /// The text was cut for the wire; the whole item is read on demand.
  public var shortened: Bool
  public var body: Body
  /// On a goal transition row: the goal it set, or `.cleared` (agent-session-journal-types.ts threadGoal).
  public var goalChange: GoalChange?
  /// The row starts a fresh context (a /clear): whatever goal was before it no longer holds.
  public var clearsContext: Bool

  public enum GoalChange: Sendable, Equatable {
    case set(ChatOptions.Goal)
    case cleared
  }

  public init?(_ json: JSONValue) {
    guard let id = json["itemId"]?.stringValue, let body = json["body"] else {
      return nil
    }
    self.id = id
    revision = json["revision"]?.intValue ?? 0
    sequence = json["sequence"]?.intValue ?? 0
    sequenceIndex = json["sequenceIndex"]?.intValue ?? 0
    observedAt = json["observedAt"]?.doubleValue ?? 0
    agentId = json["agentId"]?.stringValue
    parentAgentId = json["parentAgentId"]?.stringValue
    producerKind = json["producerKind"]?.stringValue
    let rawBody = json["body"]
    clearsContext = rawBody?["contextClear"] != nil && rawBody?["contextClear"] != .null
    switch rawBody?["threadGoal"]?["state"]?.stringValue {
    case "set":
      if let goal = rawBody?["threadGoal"]?["goal"], let objective = goal["objective"]?.stringValue {
        goalChange = .set(
          ChatOptions.Goal(
            objective: objective, status: goal["status"]?.stringValue ?? "active",
            timeUsedSeconds: goal["timeUsedSeconds"]?.doubleValue ?? 0, tokensUsed: goal["tokensUsed"]?.intValue ?? 0))
      }
    case "cleared": goalChange = .cleared
    default: break
    }
    shortened = json["shortened"]?.boolValue ?? false
    self.body = Self.body(body)
  }

  private static func body(_ json: JSONValue) -> Body {
    let kind = json["kind"]?.stringValue ?? ""
    switch kind {
    case "message":
      let role = json["role"]?.stringValue ?? "assistant"
      // A reasoning row says so itself; an assistant row is live until it carries a completion time.
      let streaming = json["state"]?.stringValue.map { $0 == "running" } ?? (role == "assistant" && json["completedAt"] == nil)
      let blocks = (json["blocks"]?.arrayValue ?? []).map(Block.init)
      let source = json["from"]
      return .message(Message(
        role: role,
        blocks: blocks,
        isStreaming: streaming,
        commandName: json["command"]?["name"]?.stringValue,
        origin: json["origin"]?.stringValue,
        agentSenders: source.flatMap { source in
          guard source["kind"]?.stringValue == "agent" else { return nil }
          return (source["senders"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue ?? $0["agent"]?.stringValue }
        }, agentMailText: mailText(source, blocks: blocks),
        isImageOperation: (json["blocks"]?.arrayValue ?? []).contains { block in
          block["type"]?.stringValue == "text"
            && ["image-operation", "generated-image"].contains(block["presentation"]?.stringValue ?? "")
        }))
    case "tool-call":
      return .toolCall(ToolCall(json))
    case "diff":
      return .diff(
        path: json["path"]?.stringValue ?? "", patch: json["patch"]?["head"]?.stringValue ?? "",
        truncated: json["patch"]?["truncated"]?.boolValue ?? false)
    case "approval":
      return .approval(prompt(json, title: json["displayName"]?.stringValue ?? json["title"]?.stringValue ?? "", detail: json["detail"]?.stringValue ?? json["description"]?.stringValue))
    case "question":
      return .question(prompt(json, title: json["question"]?.stringValue ?? "", detail: nil))
    case "status":
      return .status(text: json["text"]?.stringValue ?? "", tone: json["tone"]?.stringValue)
    case "agent-start":
      let worker = json["worker"]
      return .agentStarted(
        dispatchId: json["dispatchId"]?.stringValue ?? "",
        name: worker?["name"]?.stringValue ?? worker?["agent"]?.stringValue ?? json["agent"]?.stringValue ?? "",
        task: json["task"]?.stringValue ?? "")
    case "turn":
      return .turn(Turn(
        turnId: json["turnId"]?.stringValue ?? "", state: json["state"]?.stringValue ?? "",
        startedAt: json["startedAt"]?.doubleValue, durationMs: json["durationMs"]?.doubleValue))
    default:
      return .other(kind: kind)
    }
  }

  private static func mailText(_ source: JSONValue?, blocks: [Block]) -> String? {
    guard source?["kind"]?.stringValue == "agent", source?["orchestration"]?["message"]?.stringValue == "mail-notice",
      let messages = source?["orchestration"]?["messages"]?.arrayValue, !messages.isEmpty,
      blocks.count == 1, case .text(let canonical, _) = blocks[0] else { return nil }
    // The host counts UTF-16 units. If any message is clipped or from an older host, keep the canonical text.
    func field(_ value: JSONValue) -> String? {
      guard let bounds = value.arrayValue, bounds.count == 2, let start = bounds[0].intValue, let end = bounds[1].intValue,
        start >= 0, end >= start, end <= canonical.utf16.count,
        let range = Range(NSRange(location: start, length: end - start), in: canonical) else { return nil }
      return String(canonical[range])
    }
    var reports: [String] = []
    for message in messages {
      guard let content = message["content"], let subject = content["subject"].flatMap(field) else { return nil }
      var parts = [subject]
      for key in ["body", "payload"] {
        if let range = content[key] {
          guard let text = field(range) else { return nil }
          parts.append(text)
        }
      }
      reports.append(parts.filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }
    return reports.joined(separator: "\n\n")
  }

  private static func prompt(_ json: JSONValue, title: String, detail: String?) -> Prompt {
    func freeText(_ json: JSONValue, id: String?) -> Question.FreeText? {
      guard id != nil || json["freeTextInput"] != nil else { return nil }
      let input = json["freeTextInput"]
      return .init(
        placeholder: input?["placeholder"]?.stringValue, multiline: input?["multiline"]?.boolValue ?? false,
        allowEmpty: input?["allowEmpty"]?.boolValue ?? false)
    }
    let questions = (json["questions"]?.arrayValue ?? []).compactMap { question -> Question? in
      guard let id = question["id"]?.stringValue else { return nil }
      return Question(
        id: id, text: question["question"]?.stringValue ?? "", header: question["header"]?.stringValue,
        multiSelect: question["multiSelect"]?.boolValue ?? false,
        options: (question["options"]?.arrayValue ?? []).compactMap(PromptOption.init),
        freeText: freeText(question, id: question["freeTextQuestionId"]?.stringValue),
        skippable: question["skippable"]?.boolValue ?? false)
    }
    let answers = (json["resolution"]?["answers"]?.arrayValue ?? []).compactMap { answer -> Answer? in
      guard let id = answer["questionId"]?.stringValue else { return nil }
      return Answer(
        questionId: id, optionIds: (answer["optionIds"]?.arrayValue ?? []).compactMap(\.stringValue),
        other: answer["other"]?.stringValue)
    }
    return Prompt(
      title: title, detail: detail,
      options: (json["options"]?.arrayValue ?? []).compactMap(PromptOption.init),
      resolutionState: json["resolution"]?["state"]?.stringValue ?? "pending",
      selectedOptionId: json["resolution"]?["selectedOptionId"]?.stringValue,
      questions: questions, answers: answers)
  }
}

/// The delivery state of one of this client's sends.
public struct TranscriptSubmission: Sendable, Equatable {
  /// The `clientOperationId` the send carried.
  public var clientMessageId: String
  /// `pending`, `accepted`, `rejected`, or `unknown` (delivery unconfirmed: neither sent nor failed).
  public var dispatchState: String
  /// The journal row the message became, once accepted.
  public var providerItemId: String?
  public var reason: String?

  init?(_ json: JSONValue) {
    guard let id = json["clientMessageId"]?.stringValue else {
      return nil
    }
    clientMessageId = id
    dispatchState = json["dispatchState"]?.stringValue ?? "unknown"
    providerItemId = json["providerItemId"]?.stringValue
    reason = json["reason"]?.stringValue
  }
}

/// A chat's transcript as built from `agentSession.subscribe` frames and history pages.
/// Frames are cursor-qualified current states, not deltas: applying one twice converges.
public struct ChatTranscript: Sendable, Equatable {
  /// In journal order.
  public private(set) var items: [TranscriptItem] = []
  public private(set) var submissions: [String: TranscriptSubmission] = [:]
  /// The latest fence seen; every write names it.
  public private(set) var fence: Int?
  /// The last applied position, to resume a dropped stream from.
  public private(set) var cursor: TranscriptCursor?
  public private(set) var oldestCursor: TranscriptCursor?
  public private(set) var hasOlder = false
  /// The host's own "is it busy" verdict, when it sends one.
  public private(set) var hostWorking: Bool?
  /// The ephemeral "what it is doing" line.
  public private(set) var activity: String?
  /// Work the agent left running in the background (agents, shells, monitors), as the host last listed it.
  public private(set) var backgroundTasks: [BackgroundTask] = []
  public private(set) var subagents: [ChatSubagent] = []
  /// Messages waiting for the running turn to end (agent-session-queued-message-wire.ts), in send order.
  public private(set) var queuedMessages: [QueuedMessage] = []
  public private(set) var stopsBackgroundTasks = false

  /// The prompts that can still be answered, when the host says; nil on hosts that do not.
  public private(set) var actionablePromptIds: Set<String>?
  public private(set) var ended = false

  private var byId: [String: TranscriptItem] = [:]
  private var removedItemIds: Set<String> = []
  private struct SubagentRosterRow: Sendable, Equatable {
    var sequence: Int
    var sequenceIndex: Int
    var revision: Int
    var agents: [ChatSubagent]
  }
  /// A page can name agents whose starting rows are outside its window.
  private var subagentRoster: [String: SubagentRosterRow] = [:]

  public init() {}

  /// Applies one stream frame. Unknown frame types are ignored.
  public mutating func apply(_ frame: JSONValue) {
    switch frame["type"]?.stringValue {
    case "snapshot", "reset":
      clearRows()
      submissions = [:]
      oldestCursor = nil
      cursor = nil
      hasOlder = false
      // A snapshot restates the live state; anything a cache restored before it is dropped.
      clearExtras()
      ended = false
      if let page = frame["page"] {
        merge(page: page, replacingWindow: true)
      } else {
        rebuild()
      }
      noteFence(frame["fence"])
      noteExtras(frame)
    case "batch":
      guard let batch = frame["batch"] else {
        return
      }
      if let next = TranscriptCursor(batch["cursor"]) {
        if let cursor, cursor.epoch != next.epoch {
          // The journal was renumbered; nothing held is comparable any more.
          clearRows()
          clearExtras()
          submissions = [:]
          oldestCursor = nil
          hasOlder = false
        }
        cursor = next
      }
      upsert(batch, live: true)
      noteFence(frame["fence"])
      noteExtras(frame)
      rebuild()
    case "end":
      ended = true
    default:
      break
    }
  }

  /// Merges an older page from `agentSession.history`.
  public mutating func prepend(page: JSONValue) {
    merge(page: page, replacingWindow: false)
  }

  mutating func replaceTerminalRows(_ rows: [TranscriptItem], before: TranscriptCursor?, working: Bool) {
    byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
    oldestCursor = before
    hasOlder = before != nil
    hostWorking = working
    rebuild()
  }

  /// What a cache restored is history only: whether the agent works, its background tasks and queue, and
  /// the fence and cursor a write would cite are the host's to say again, so they are dropped until its
  /// snapshot arrives.
  public mutating func forgetLiveState() {
    clearExtras()
    hostWorking = false
    fence = nil
    cursor = nil
  }

  private mutating func clearExtras() {
    hostWorking = nil
    activity = nil
    backgroundTasks = []
    stopsBackgroundTasks = false
    queuedMessages = []
    actionablePromptIds = nil
  }

  private mutating func clearRows() {
    byId.removeAll()
    removedItemIds.removeAll()
    subagentRoster.removeAll()
  }

  /// The fence a mutation reply reported.
  public mutating func noteFence(_ fence: Int?) {
    if let fence {
      self.fence = max(fence, self.fence ?? 0)
    }
  }

  /// The running turn, which Stop names.
  public var runningTurnId: String? {
    for item in items.reversed() where item.agentId == nil {
      if case .turn(let turn) = item.body {
        return turn.state == "running" ? turn.turnId : nil
      }
    }
    return nil
  }

  public var isWorking: Bool {
    hostWorking ?? (runningTurnId != nil)
  }

  /// Whether a prompt row can still be answered.
  public func isActionable(_ item: TranscriptItem) -> Bool {
    let pending: Bool
    switch item.body {
    case .approval(let prompt), .question(let prompt):
      pending = prompt.isPending
    default:
      return false
    }
    return pending && (actionablePromptIds?.contains(item.id) ?? true)
  }

  private mutating func merge(page: JSONValue, replacingWindow: Bool) {
    if !replacingWindow, let epoch = page["epoch"]?.stringValue,
      let currentEpoch = cursor?.epoch ?? oldestCursor?.epoch, epoch != currentEpoch { return }
    upsert(page)
    for named in page["subagentRoster"]?.arrayValue ?? [] {
      let revision = named["revision"]?.intValue ?? 0
      guard let id = named["itemId"]?.stringValue, let sequence = named["sequence"]?.intValue,
        let agent = named["entry"].flatMap(ChatSubagent.init), !removedItemIds.contains(id),
        (byId[id]?.revision ?? -1) < revision, (subagentRoster[id]?.revision ?? -1) <= revision else { continue }
      if var held = subagentRoster[id], held.revision == revision {
        // Each page can name a different subset of the same legacy group.
        if !held.agents.contains(where: { $0.id == agent.id }) {
          held.agents.append(agent)
          subagentRoster[id] = held
        }
      } else {
        subagentRoster[id] = .init(
          sequence: sequence, sequenceIndex: named["sequenceIndex"]?.intValue ?? 0, revision: revision, agents: [agent])
      }
    }
    noteFence(page["fence"])
    let window = page["window"]
    if replacingWindow {
      cursor = TranscriptCursor(page["liveCursor"]) ?? TranscriptCursor(window?["newest"]) ?? TranscriptCursor(window?["nextCursor"])
      noteExtras(page)
    }
    // Only a page that reaches further back moves the paging position.
    if page["direction"]?.stringValue != "after" {
      if let oldest = TranscriptCursor(window?["oldest"]) ?? TranscriptCursor(window?["nextCursor"]) {
        oldestCursor = oldest
      }
      hasOlder = page["hasOlder"]?.boolValue ?? false
    }
    rebuild()
  }

  private mutating func upsert(_ container: JSONValue, live: Bool = false) {
    for item in (container["items"]?.arrayValue ?? []).compactMap(TranscriptItem.init) {
      guard (live || !removedItemIds.contains(item.id)), (byId[item.id]?.revision ?? -1) <= item.revision else { continue }
      if live { removedItemIds.remove(item.id) }
      byId[item.id] = item
      if let roster = subagentRoster[item.id], roster.revision <= item.revision {
        subagentRoster[item.id] = nil
      }
    }
    for id in (container["removedItemIds"]?.arrayValue ?? []).compactMap(\.stringValue) {
      removedItemIds.insert(id)
      byId[id] = nil
      subagentRoster[id] = nil
    }
    for submission in (container["submissions"]?.arrayValue ?? []).compactMap(TranscriptSubmission.init) {
      submissions[submission.clientMessageId] = submission
    }
  }

  private mutating func noteFence(_ json: JSONValue?) {
    noteFence(json?.intValue)
  }

  private mutating func noteExtras(_ frame: JSONValue) {
    if let working = frame["working"]?.boolValue {
      hostWorking = working
    }
    // Absent means unchanged; null clears.
    if let activity = frame["activity"] {
      self.activity = activity["text"]?.stringValue
    }
    // Absent means unchanged; null clears.
    if let roster = frame["backgroundTasks"] {
      let live = roster["state"]?.stringValue == "monitoring"
      backgroundTasks = live ? (roster["tasks"]?.arrayValue ?? []).compactMap(BackgroundTask.init) : []
      stopsBackgroundTasks = live && (roster["supportsStopAll"]?.boolValue ?? true)
    }
    // Absent means unchanged; null or [] empties it.
    if let queued = frame["queuedMessages"] {
      queuedMessages = (queued.arrayValue ?? []).compactMap(QueuedMessage.init).sorted { $0.position < $1.position }
    }
    if let ids = frame["actionablePromptIds"]?.arrayValue {
      actionablePromptIds = Set(ids.compactMap(\.stringValue))
    }
  }

  private mutating func rebuild() {
    // Journal order, never arrival or clock order.
    items = byId.values.sorted { ($0.sequence, $0.sequenceIndex, $0.id) < ($1.sequence, $1.sequenceIndex, $1.id) }
    var roster = subagentRoster
    for item in items where roster[item.id] == nil {
      guard case .message(let message) = item.body else { continue }
      let agents = message.subagents
      if !agents.isEmpty {
        roster[item.id] = .init(sequence: item.sequence, sequenceIndex: item.sequenceIndex, revision: item.revision, agents: agents)
      }
    }
    let ordered = roster.sorted {
      ($0.value.sequence, $0.value.sequenceIndex, $0.key) < ($1.value.sequence, $1.value.sequenceIndex, $1.key)
    }
    var seen = Set<String>()
    let newestFirst = ordered.reversed().flatMap { $0.value.agents.reversed() }
    subagents = Array(newestFirst.filter { seen.insert($0.id).inserted }.reversed())
    for item in items {
      if let id = item.agentId, item.producerKind != "background", seen.insert(id).inserted {
        var agent = ChatSubagent(id: id)
        agent.parentId = item.parentAgentId
        subagents.append(agent)
      }
    }
  }
}

/// A message the host holds until the running turn ends, then sends on its own.
public struct QueuedMessage: Sendable, Equatable, Identifiable {
  public var id: String
  public var position: Int
  public var text: String
  /// `waiting`, or `returned` when sending it failed and it waits for the person.
  public var state: String
  /// Sent to steer the running turn; held only until the turn takes it in.
  public var steers: Bool

  init?(_ json: JSONValue) {
    guard let id = json["messageId"]?.stringValue else { return nil }
    self.id = id
    position = json["position"]?.intValue ?? 0
    let body = json["body"]
    let blocks = (body?["blocks"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
    text = blocks.isEmpty ? (body?["text"]?.stringValue ?? "") : blocks.joined(separator: "\n\n")
    state = json["state"]?.stringValue ?? "waiting"
    steers = json["steers"]?.boolValue ?? false
  }
}

/// One piece of background work (agent-session-background-task-wire.ts).
public struct BackgroundTask: Sendable, Equatable, Identifiable {
  /// `agent`, `workflow`, `command`, `monitor`, `unknown`.
  public var id: String
  public var kind: String
  public var label: String
  public var state: String?
  /// Host epoch milliseconds.
  public var startedAt: Double?
  public var totalTokens: Int?
  public var stoppable: Bool

  init?(_ json: JSONValue) {
    guard let id = json["id"]?.stringValue else { return nil }
    self.id = id
    kind = json["kind"]?.stringValue ?? "unknown"
    label = json["description"]?.stringValue ?? json["name"]?.stringValue ?? ""
    state = json["state"]?.stringValue
    startedAt = json["startedAt"]?.doubleValue
    totalTokens = json["totalTokens"]?.intValue
    stoppable = json["stoppable"]?.boolValue ?? true
  }
}
