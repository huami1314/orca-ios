import Foundation
import Testing

@testable import OrcaCore

@Suite struct WorktreeCatalogTests {
  static func row(_ id: String, name: String? = nil) -> JSONValue {
    ["worktreeId": .string(id), "repoId": "r1", "repo": "orca", "branch": "main", "displayName": .string(name ?? id), "path": "/p"]
  }

  @Test func appliesFullUnchangedAndDeltaReplies() {
    var catalog = WorktreeCatalog()
    #expect(catalog.requestParams["afterSnapshotId"] == nil)
    #expect(catalog.requestParams["limit"] == 10_000)

    #expect(catalog.apply(["worktrees": [Self.row("a"), Self.row("b"), Self.row("c")], "snapshotId": "s1"]) == .replaced)
    #expect(catalog.requestParams["afterSnapshotId"] == "s1")
    #expect(catalog.apply(["unchanged": true, "snapshotId": "s1"]) == .unchanged)

    // c moved first, b was renamed, a is gone.
    let delta: JSONValue = ["snapshotId": "s2", "baseSnapshotId": "s1", "rowsFromBase": [2, Self.row("b", name: "renamed")]]
    #expect(catalog.apply(delta) == .replaced)
    #expect(catalog.worktrees.map(\.title) == ["c", "renamed"])
    #expect(catalog.snapshotId == "s2")
  }

  @Test func dropsItsSnapshotOnAnythingThatDoesNotFit() {
    var catalog = WorktreeCatalog()
    _ = catalog.apply(["worktrees": [Self.row("a")], "snapshotId": "s1"])
    #expect(catalog.apply(["snapshotId": "s2", "baseSnapshotId": "other", "rowsFromBase": [0]]) == .needsFullRead)
    #expect(catalog.snapshotId == nil)

    _ = catalog.apply(["worktrees": [Self.row("a")], "snapshotId": "s1"])
    #expect(catalog.apply(["snapshotId": "s2", "baseSnapshotId": "s1", "rowsFromBase": [4]]) == .needsFullRead)
    _ = catalog.apply(["worktrees": [Self.row("a")], "snapshotId": "s1"])
    #expect(catalog.apply(["unchanged": true, "snapshotId": "zzz"]) == .needsFullRead)
    // One unreadable row refuses the whole reply, and the rows held stay.
    #expect(catalog.apply(["worktrees": [Self.row("x"), ["nope": 1]], "snapshotId": "s3"]) == .needsFullRead)
    #expect(catalog.worktrees.map(\.id) == ["a"])
  }

  @Test func readsStatusAndAgents() throws {
    var json = Self.row("a")
    if case .object(var object) = json {
      object["status"] = "active"
      object["sidebarStatus"] = "permission"
      object["agents"] = [["paneKey": "t:l", "state": "blocked", "agentType": "claude", "prompt": "fix it", "taskTitle": "Fix the build"]]
      object["linkedPR"] = ["number": 12, "state": "open"]
      json = .object(object)
    }
    let worktree = try #require(Worktree(json))
    #expect(worktree.displayStatus == "permission")
    #expect(worktree.needsAttention)
    #expect(worktree.agents.first?.title == "Fix the build")
    #expect(worktree.linkedPR?.number == 12)
    #expect(worktree.selector == "id:a")
  }

  @Test func groupsWorkersAndUsesTheAgentsListVerdict() throws {
    let parent = try #require(Worktree.Agent(["paneKey": "lead:l", "state": "done"]))
    let worker = try #require(Worktree.Agent([
      "paneKey": "worker:l", "parentPaneKey": "lead:l", "state": "working",
      "activity": ["listed": true, "childOf": "lead:l", "status": "blocked", "title": "Review"],
    ]))
    let independent = try #require(Worktree.Agent([
      "paneKey": "new:l", "parentPaneKey": "worker:l", "activity": ["listed": true],
    ]))
    let panes = [independent, worker, parent]
    let workspace = Worktree.Agent.lineage(panes)
    #expect(workspace.map(\.entry.paneKey) == ["lead:l"])
    #expect(workspace.first?.children.first?.children.first?.entry.paneKey == "new:l")
    let agents = Worktree.Agent.lineage(panes, forAgentsTab: true)
    #expect(agents.map(\.entry.paneKey) == ["new:l", "lead:l"])
    #expect(agents.last?.children.first?.entry.listState == "blocked")
    #expect(agents.last?.children.first?.entry.listTitle == "Review")
  }

  @Test func keepsUnlinkedAndCyclicPanesVisible() {
    let agents: [JSONValue] = [
      ["paneKey": "missing", "parentPaneKey": "unknown"],
      ["paneKey": "self", "parentPaneKey": "self"],
      ["paneKey": "a", "parentPaneKey": "b"],
      ["paneKey": "b", "parentPaneKey": "a"],
      ["paneKey": "a", "parentPaneKey": "missing"],
    ]
    let roots = Worktree.Agent.lineage(agents.compactMap(Worktree.Agent.init))
    #expect(roots.map(\.entry.paneKey) == ["missing", "self", "a", "b"])
    #expect(roots.allSatisfy { $0.children.isEmpty })
  }

  @Test func readsLiveProviderChildrenAndKeepsTheirOwnStatusSeparate() throws {
    let parent = try #require(Worktree.Agent([
      "paneKey": "lead:l", "state": "working", "mainAgent": ["state": "done"],
      "children": [
        ["id": "child", "kind": "agent", "parentChildWorkId": "owner", "state": "working",
         "description": "Review", "operation": ["toolName": "Read", "input": "README.md"]],
        ["id": "owner", "kind": "agent", "state": "done", "membership": "settled", "outcome": "succeeded"],
        ["id": "shell", "kind": "command", "state": "working"],
        ["id": "old", "kind": "agent", "state": "done", "membership": "settled", "outcome": "succeeded"],
      ],
      "subagents": [["id": "legacy", "state": "working"]],
    ]))
    #expect(parent.state == "working")
    #expect(parent.mainState == "done")
    #expect(parent.childLineage.map(\.entry.id) == ["owner"])
    #expect(parent.childLineage.first?.children.first?.entry.label == "Review")
    #expect(parent.childLineage.first?.children.first?.entry.detail == "Read · README.md")

    let legacy = try #require(Worktree.Agent([
      "paneKey": "legacy:l", "subagentObservation": "unverifiable",
      "subagents": [["id": "helper", "state": "working", "description": "Tests"]],
    ]))
    #expect(legacy.childLineage.first?.entry.label == "Tests")
    #expect(legacy.childLineage.first?.entry.state == "unverifiable")
  }
}

@Suite struct SessionTabsTests {
  @Test func ordersByGroupsAndReadsEveryKind() {
    let tabs = SessionTabs([
      "activeTabId": "chat",
      "tabGroups": [["id": "g", "tabOrder": ["chat", "term"]]],
      "tabs": [
        ["type": "terminal", "id": "term", "title": "zsh", "customTitle": "server", "status": "ready", "terminal": "h-1", "isActive": false],
        ["type": "browser", "id": "web", "title": "Docs", "url": "https://x.test", "isActive": false],
        ["type": "agent-session", "id": "chat", "title": "Fix build", "sessionId": "s-12345678", "agent": "claude", "isActive": true],
        ["type": "terminal", "id": "pending", "title": "claude", "status": "pending-handle", "terminal": nil],
        ["type": "hologram", "id": "new", "title": "Future"],
      ],
    ])
    #expect(tabs.tabs.map(\.id) == ["chat", "term", "web", "pending", "new"])
    #expect(tabs.tabs[0].kind == .agentSession(sessionId: "s-12345678", agent: "claude"))
    #expect(tabs.tabs[1].title == "server")
    #expect(tabs.tabs[1].terminalHandle == "h-1")
    #expect(tabs.tabs[3].kind == .terminal(handle: nil))
    #expect(tabs.tabs[4].kind == .unknown(type: "hologram"))
    #expect(tabs.activeTabId == "chat")
    #expect(tabs.agentTab(sessionId: "s-12345678", paneKey: "term:leaf")?.id == "chat")
    #expect(tabs.agentTab(sessionId: nil, paneKey: "term:leaf")?.id == "term")
    #expect(tabs.agentTab(sessionId: "gone", paneKey: "invalid") == nil)
  }
}

@Suite struct WorkingAgentTests {
  @Test func collectsOnlyConfirmedActiveIdentitiesAcrossHosts() throws {
    let sharedPane = "tab:leaf"
    let workspace = try #require(Worktree([
      "worktreeId": "w", "repoId": "r", "displayName": "Client",
      "agents": [
        ["paneKey": .string(sharedPane), "state": "working", "agentType": "codex", "displayName": "Review",
         "conversationName": "Private conversation title", "address": "orca_session_id:review"],
        ["paneKey": "child-owner", "state": "working", "agentType": "codex", "mainAgent": ["state": "done"],
         "address": "orca_session_id:owner",
         "children": [["id": "c1", "kind": "agent", "state": "working", "description": "Private task",
                       "lastMessage": "Private reply", "providerId": "provider-child"]]],
        ["paneKey": "monitor", "state": "working", "workingMode": "monitoring"],
        ["paneKey": "waiting", "state": "waiting"],
        ["paneKey": "lost", "state": "working", "activity": ["listed": true, "status": "unverifiable"]],
        ["paneKey": "legacy", "state": "working", "taskTitle": "Private task",
         "conversationName": "Private conversation title", "prompt": "Private prompt", "orcaSessionId": "terminal-session"],
      ],
    ]))
    let archived = try #require(Worktree([
      "worktreeId": "old", "repoId": "r", "isArchived": true,
      "agents": [["paneKey": "archived", "state": "working"]],
    ]))
    let hostA = UUID()
    let hostB = UUID()
    let first = WorkingAgent.inCatalog([workspace, archived, workspace], host: hostA)
    let second = WorkingAgent.inCatalog([workspace], host: hostB)
    #expect(first.map(\.id.pane) == ["child-owner", "legacy", sharedPane, "waiting"])
    #expect(first.first?.leadActivity == nil)
    #expect(first.first?.children == [.init(agentType: nil, owningAgentType: "codex", activity: .working)])
    #expect(first.compactMap(\.name) == ["Review"])
    #expect(first.map(\.structuredSessionId) == ["owner", nil, "review", nil])
    #expect(first.map(\.activity) == [.working, .working, .working, .needsDecision])
    #expect(Set((first + second).map(\.id)).count == 8)
  }

  @Test func distinguishesStructuredQuestionsAndUsesGenericAttentionForOtherWaits() throws {
    let workspace = try #require(Worktree([
      "worktreeId": "active", "repoId": "r",
      "agents": [
        ["paneKey": "answer", "state": "waiting", "mainAgent": ["state": "waiting"], "address": "orca_session_id:answer",
         "activity": ["listed": true, "status": "permission"]],
        ["paneKey": "approval", "state": "blocked", "mainAgent": ["state": "blocked"], "address": "orca_session_id:approval"],
        ["paneKey": "old-host", "state": "working", "activity": ["listed": true, "status": "permission"]],
        ["paneKey": "child-parent", "state": "waiting", "mainAgent": ["state": "done"], "children": [
          ["id": "waiting-child", "kind": "agent", "state": "waiting"],
          ["id": "blocked-child", "kind": "agent", "state": "blocked"],
          ["id": "settled-child", "kind": "agent", "state": "waiting", "membership": "settled", "outcome": "failed"],
        ]],
        ["paneKey": "lost", "state": "waiting", "mainAgent": ["state": "waiting"],
         "activity": ["listed": true, "status": "unverifiable"]],
        ["paneKey": "restored", "state": "blocked", "restoredUnconfirmed": true],
        ["paneKey": "failed", "state": "done", "mainAgent": ["state": "done"], "activity": ["status": "failed"]],
      ],
    ]))
    let agents = WorkingAgent.inCatalog([workspace], host: UUID())
    #expect(agents.map(\.id.pane) == ["answer", "approval", "child-parent", "old-host"])
    #expect(agents.map(\.activity) == [.needsAnswer, .needsDecision, .needsDecision, .needsDecision])
    #expect(agents.first { $0.id.pane == "child-parent" }?.children.map(\.activity) == [.needsDecision])
  }

  @Test func groupsWorkingAndWaitingDescendantsAcrossWorkspacesOnOneHost() throws {
    let main = try #require(Worktree([
      "worktreeId": "a", "repoId": "r", "displayName": "Release",
      "agents": [["paneKey": "lead", "state": "done", "agentType": "codex", "displayName": "Release review",
                  "children": [["id": "review", "kind": "agent", "state": "working", "agentType": "explorer"]]]],
    ]))
    let workers = try #require(Worktree([
      "worktreeId": "b", "repoId": "r",
      "agents": [
        ["paneKey": "worker", "state": "working", "agentType": "gemini", "parentPaneKey": "lead",
         "children": [["id": "local", "kind": "agent", "state": "working"]]],
        ["paneKey": "nested", "state": "waiting", "agentType": "claude", "mainAgent": ["state": "waiting"],
         "address": "orca_session_id:nested", "activity": ["listed": true, "childOf": "worker"]],
        ["paneKey": "independent", "state": "working", "parentPaneKey": "missing"],
      ],
    ]))
    let host = UUID()
    let groups = WorkingAgent.inCatalog([workers, main], host: host)
    #expect(groups.map(\.id.pane) == ["lead", "independent"])
    let lead = try #require(groups.first)
    #expect(lead.name == "Release review")
    #expect(lead.leadActivity == nil)
    #expect(lead.activity == .needsAnswer)
    #expect(lead.children.map(\.agentType) == ["explorer", "gemini", nil, "claude"])
    #expect(lead.children.map(\.owningAgentType) == ["codex", nil, "gemini", nil])
    #expect(lead.children.map(\.activity) == [.working, .working, .working, .needsAnswer])
    #expect(groups.last?.isWorker == true)
    #expect(WorkingAgent.inCatalog([main], host: host).first?.id == lead.id)
    #expect(WorkingAgent.inCatalog([workers], host: UUID()).map(\.id.pane) == ["independent", "worker"])
  }

  @Test func scrollsOneLineAtATimeAndWrapsWithTwoVisibleAgents() {
    let host = UUID()
    let a = WorkingAgent.ID(host: host, pane: "a")
    let b = WorkingAgent.ID(host: host, pane: "b")
    let other = UUID()
    let c = WorkingAgent.ID(host: other, pane: "a")
    let d = WorkingAgent.ID(host: other, pane: "b")
    let e = WorkingAgent.ID(host: other, pane: "c")
    let agents = [a, b, c, d, e]
    var rotation = WorkingAgentRotation()
    #expect(rotation.page(in: agents, at: 0, rotating: true) == .init(indices: [0, 1], nextIndex: 2, didAdvance: false))
    #expect(rotation.page(in: agents, at: 2.9, rotating: true) == .init(indices: [0, 1], nextIndex: 2, didAdvance: false))
    #expect(rotation.page(in: agents, at: 3, rotating: true) == .init(indices: [1, 2], nextIndex: 3, didAdvance: true))
    #expect(rotation.page(in: agents, at: 6, rotating: true) == .init(indices: [2, 3], nextIndex: 4, didAdvance: true))
    #expect(rotation.page(in: agents, at: 9, rotating: true) == .init(indices: [3, 4], nextIndex: 0, didAdvance: true))
    #expect(rotation.page(in: agents, at: 12, rotating: true) == .init(indices: [4, 0], nextIndex: 1, didAdvance: true))
    #expect(rotation.page(in: agents, at: 15, rotating: true) == .init(indices: [0, 1], nextIndex: 2, didAdvance: true))
  }

  @Test func keepsTheVisibleAgentWhenTheRosterChangesAndStopsWithSmallLists() {
    let host = UUID()
    let agents = ["a", "b", "c", "d"].map { WorkingAgent.ID(host: host, pane: $0) }
    let (a, b, c, d) = (agents[0], agents[1], agents[2], agents[3])
    var rotation = WorkingAgentRotation()
    #expect(rotation.page(in: agents, at: 0, rotating: true).indices == [0, 1])
    #expect(rotation.page(in: agents, at: 3, rotating: true).indices == [1, 2])
    // b leaves. c stays on screen, in the first slot with a fresh interval.
    let remaining = [a, c, d]
    #expect(rotation.page(in: remaining, at: 5, rotating: true) == .init(indices: [1, 2], nextIndex: 0, didAdvance: false))
    #expect(!rotation.page(in: remaining, at: 7.9, rotating: true).didAdvance)
    #expect(rotation.page(in: remaining, at: 8, rotating: true).indices == [2, 0])
    #expect(rotation.page(in: [d, a, b, c], at: 9, rotating: true).indices == [0, 1])
    #expect(!rotation.page(in: remaining, at: 15, rotating: false).didAdvance)
    #expect(!rotation.page(in: remaining, at: 16, rotating: true).didAdvance)
    #expect(rotation.page(in: [c, d], at: 21, rotating: true) == .init(indices: [0, 1], nextIndex: nil, didAdvance: false))
    #expect(rotation.page(in: [d], at: 30, rotating: true).indices == [0])
    #expect(rotation.page(in: [], at: 31, rotating: true).indices.isEmpty)
  }

  @Test func showsANewDecisionImmediatelyAndGivesItAFullInterval() {
    let host = UUID()
    let agents = ["a", "b", "c", "d"].map { WorkingAgent.ID(host: host, pane: $0) }
    var rotation = WorkingAgentRotation()
    #expect(rotation.page(in: agents, at: 0, rotating: true).indices == [0, 1])
    #expect(rotation.page(in: agents, at: 1.5, rotating: true, preferring: agents[2])
      == .init(indices: [2, 3], nextIndex: 0, didAdvance: false))
    #expect(!rotation.page(in: agents, at: 4.4, rotating: true).didAdvance)
    #expect(rotation.page(in: agents, at: 4.5, rotating: true) == .init(indices: [3, 0], nextIndex: 1, didAdvance: true))
  }

  @Test func pinsSingleAttentionInFirstRowAndRotatesSecondRow() {
    let host = UUID()
    let agents = ["attn", "w1", "w2", "w3"].map { WorkingAgent.ID(host: host, pane: $0) }
    let attn = agents[0]
    var rotation = WorkingAgentRotation()
    #expect(rotation.page(in: agents, at: 0, rotating: true, pinned: attn)
      == .init(indices: [0, 1], nextIndex: 2, didAdvance: false, scrollsOnlySecondRow: true))
    #expect(rotation.page(in: agents, at: 2.9, rotating: true, pinned: attn)
      == .init(indices: [0, 1], nextIndex: 2, didAdvance: false, scrollsOnlySecondRow: true))
    #expect(rotation.page(in: agents, at: 3.0, rotating: true, pinned: attn)
      == .init(indices: [0, 2], nextIndex: 3, didAdvance: true, scrollsOnlySecondRow: true))
    #expect(rotation.page(in: agents, at: 6.0, rotating: true, pinned: attn)
      == .init(indices: [0, 3], nextIndex: 1, didAdvance: true, scrollsOnlySecondRow: true))
    #expect(rotation.page(in: agents, at: 9.0, rotating: true, pinned: attn)
      == .init(indices: [0, 1], nextIndex: 2, didAdvance: true, scrollsOnlySecondRow: true))
    // Dropping back to 2 agents stops rotation cleanly.
    #expect(rotation.page(in: [attn, agents[1]], at: 12.0, rotating: true, pinned: attn)
      == .init(indices: [0, 1], nextIndex: nil, didAdvance: false, scrollsOnlySecondRow: false))
    // Unpinning (e.g. a second attention item arrives) restores full two-row rotation.
    #expect(rotation.page(in: agents, at: 13.0, rotating: true, pinned: nil)
      == .init(indices: [0, 1], nextIndex: 2, didAdvance: false, scrollsOnlySecondRow: false))
    #expect(rotation.page(in: agents, at: 15.0, rotating: true, pinned: nil)
      == .init(indices: [1, 2], nextIndex: 3, didAdvance: true, scrollsOnlySecondRow: false))
  }

  @Test func splitsAttentionAndWorkingZonesWhenMultipleAttentionExist() {
    let host = UUID()
    let agents = ["dec1", "ans1", "w1", "w2", "w3"].map { WorkingAgent.ID(host: host, pane: $0) }
    var rotation = WorkingAgentRotation()
    #expect(rotation.page(in: agents, at: 0, rotating: true, splitAt: 2)
      == .init(indices: [0, 2], nextIndex: 1, secondaryNextIndex: 3, didAdvance: false, splitAt: 2))
    #expect(rotation.page(in: agents, at: 2.9, rotating: true, splitAt: 2)
      == .init(indices: [0, 2], nextIndex: 1, secondaryNextIndex: 3, didAdvance: false, splitAt: 2))
    #expect(rotation.page(in: agents, at: 3.0, rotating: true, splitAt: 2)
      == .init(indices: [1, 3], nextIndex: 0, secondaryNextIndex: 4, didAdvance: true, splitAt: 2))
    #expect(rotation.page(in: agents, at: 6.0, rotating: true, splitAt: 2)
      == .init(indices: [0, 4], nextIndex: 1, secondaryNextIndex: 2, didAdvance: true, splitAt: 2))
    // A brand-new attention jumps to Row 1 immediately without disturbing Row 2's working anchor.
    let expanded = [agents[0], WorkingAgent.ID(host: host, pane: "dec2"), agents[1], agents[2], agents[3], agents[4]]
    #expect(rotation.page(in: expanded, at: 7.0, rotating: true, preferring: expanded[1], splitAt: 3)
      == .init(indices: [1, 5], nextIndex: 2, secondaryNextIndex: 3, didAdvance: false, splitAt: 3))
    // When only one working agent remains, Row 1 rotates attention while Row 2 stays steady on that worker.
    let oneWorker = [agents[0], agents[1], agents[2]]
    var solo = WorkingAgentRotation()
    #expect(solo.page(in: oneWorker, at: 0, rotating: true, splitAt: 2)
      == .init(indices: [0, 2], nextIndex: 1, secondaryNextIndex: nil, didAdvance: false, splitAt: 2))
    #expect(solo.page(in: oneWorker, at: 3.0, rotating: true, splitAt: 2)
      == .init(indices: [1, 2], nextIndex: 0, secondaryNextIndex: nil, didAdvance: true, splitAt: 2))
  }

  @Test func ranksDecisionsAheadOfQuestionsAndWorkingAndCarriesWorktreeMetadata() throws {
    let workspace = try #require(Worktree([
      "worktreeId": "wt-42", "repoId": "r", "displayName": "API",
      "agents": [
        ["paneKey": "p1", "state": "working", "updatedAt": 1_700_000_005_000],
      ],
    ]))
    let agents = WorkingAgent.inCatalog([workspace], host: UUID())
    #expect(agents.first?.worktreeId == "wt-42")
    #expect(agents.first?.updatedAt == 1_700_000_005_000)
    #expect(WorkingAgent.Activity.needsDecision.priority < WorkingAgent.Activity.needsAnswer.priority)
    #expect(WorkingAgent.Activity.needsAnswer.priority < WorkingAgent.Activity.working.priority)
  }

  @Test func stepsForwardAndBackwardManuallyEvenWhileRotationIsPaused() {
    let host = UUID()
    let agents = ["a", "b", "c", "d"].map { WorkingAgent.ID(host: host, pane: $0) }
    var full = WorkingAgentRotation()
    #expect(full.page(in: agents, at: 0, rotating: false).indices == [0, 1])
    // Backward wraps 0 -> 3 cleanly while paused.
    #expect(full.page(in: agents, at: 1, rotating: false, step: -1)
      == .init(indices: [3, 0], nextIndex: 1, didAdvance: true, stepDirection: -1))
    // Forward steps 3 -> 0 cleanly while paused.
    #expect(full.page(in: agents, at: 2, rotating: false, step: 1)
      == .init(indices: [0, 1], nextIndex: 2, didAdvance: true, stepDirection: 1))
    // Pin-1 backward steps row 2 while keeping row 1 pinned.
    var pinned = WorkingAgentRotation()
    #expect(pinned.page(in: agents, at: 0, rotating: false, pinned: agents[0]).indices == [0, 1])
    #expect(pinned.page(in: agents, at: 1, rotating: false, pinned: agents[0], step: -1)
      == .init(indices: [0, 3], nextIndex: 1, didAdvance: true, stepDirection: -1, scrollsOnlySecondRow: true))
    // Split-zone backward steps both zones cleanly.
    let splitAgents = ["d1", "a1", "w1", "w2", "w3"].map { WorkingAgent.ID(host: host, pane: $0) }
    var split = WorkingAgentRotation()
    #expect(split.page(in: splitAgents, at: 0, rotating: false, splitAt: 2).indices == [0, 2])
    #expect(split.page(in: splitAgents, at: 1, rotating: false, splitAt: 2, step: -1)
      == .init(indices: [1, 4], nextIndex: 0, secondaryNextIndex: 2, didAdvance: true, stepDirection: -1, splitAt: 2))
  }

  @Test func detectsCrossHostDuplicateTitlesOnlyAcrossDistinctHosts() {
    let hostA = UUID()
    let hostB = UUID()
    let duplicates = WorkingAgent.crossHostDuplicateTitles(in: [
      (host: hostA, title: "Release  review"),
      (host: hostB, title: "release review"),
      (host: hostA, title: "iOS build"),
      (host: hostA, title: "iOS build"),
      (host: hostB, title: "API Perf"),
    ])
    #expect(duplicates == ["release review"])
    #expect(duplicates.contains(WorkingAgent.normalizedTitleKey("Release review")))
    #expect(!duplicates.contains(WorkingAgent.normalizedTitleKey("iOS build")))
    #expect(!duplicates.contains(WorkingAgent.normalizedTitleKey("API Perf")))
  }
}

@Suite struct ChatTranscriptTests {
  static func item(_ id: String, _ sequence: Int, revision: Int = 1, body: JSONValue) -> JSONValue {
    ["itemId": .string(id), "revision": .number(Double(revision)), "sequence": .number(Double(sequence)), "observedAt": 1, "body": body]
  }

  static func message(_ role: String, _ text: String, done: Bool = true) -> JSONValue {
    var body: [String: JSONValue] = ["kind": "message", "role": .string(role), "blocks": [["type": "text", "text": .string(text)]]]
    if done {
      body["completedAt"] = 5
    }
    return .object(body)
  }

  static func cursor(_ sequence: Int, epoch: String = "e1") -> JSONValue {
    ["epoch": .string(epoch), "sequence": .number(Double(sequence))]
  }

  static var snapshot: JSONValue {
    [
      "type": "snapshot", "sessionId": "s", "fence": 3,
      "page": [
        "epoch": "e1", "direction": "tail", "hasOlder": true, "hasNewer": false,
        "items": [
          item("u1", 10, body: message("user", "hello")),
          item("t1", 11, body: ["kind": "turn", "turnId": "turn-1", "state": "running"]),
        ],
        "removedItemIds": [], "submissions": [],
        "window": ["oldest": cursor(10), "newest": cursor(11), "nextCursor": cursor(11)],
      ],
    ]
  }

  @Test func buildsFromASnapshotAndStreamsABatch() {
    var transcript = ChatTranscript()
    transcript.apply(Self.snapshot)
    #expect(transcript.items.map(\.id) == ["u1", "t1"])
    #expect(transcript.fence == 3)
    #expect(transcript.cursor?.sequence == 11)
    #expect(transcript.hasOlder)
    #expect(transcript.runningTurnId == "turn-1")
    #expect(transcript.isWorking)

    let growing: JSONValue = [
      "type": "batch", "sessionId": "s", "activity": ["turnId": "turn-1", "text": "Reading files"],
      "batch": ["cursor": Self.cursor(12), "removedItemIds": [], "submissions": [],
                "items": [Self.item("a1", 12, body: Self.message("assistant", "Hel", done: false))]],
    ]
    transcript.apply(growing)
    #expect(transcript.activity == "Reading files")
    guard case .message(let partial) = transcript.items.last?.body else {
      Issue.record("expected a message")
      return
    }
    #expect(partial.isStreaming && partial.text == "Hel")

    let finished: JSONValue = [
      "type": "batch", "sessionId": "s", "working": false, "activity": nil, "fence": 4,
      "batch": ["cursor": Self.cursor(13), "removedItemIds": [], "submissions": [],
                "items": [
                  Self.item("a1", 12, revision: 2, body: Self.message("assistant", "Hello there")),
                  Self.item("t1", 11, revision: 2, body: ["kind": "turn", "turnId": "turn-1", "state": "completed"]),
                ]],
    ]
    transcript.apply(finished)
    // A duplicate frame, and a stale revision arriving late, both converge.
    transcript.apply(finished)
    transcript.apply(growing)
    #expect(transcript.items.map(\.id) == ["u1", "t1", "a1"])
    guard case .message(let whole) = transcript.items.last?.body else {
      Issue.record("expected a message")
      return
    }
    #expect(!whole.isStreaming && whole.text == "Hello there")
    #expect(transcript.runningTurnId == nil)
    #expect(!transcript.isWorking)
    #expect(transcript.fence == 4)
  }

  @Test func readsSideQuestions() {
    #expect(ChatCommand.sideQuestion("/btw is this community run?") == "is this community run?")
    #expect(ChatCommand.sideQuestion("  /SIDE  why? ") == "why?")
    #expect(ChatCommand.sideQuestion("/btw") == "")
    #expect(ChatCommand.sideQuestion("/btwx hi") == nil)
    #expect(ChatCommand.sideQuestion("btw hi") == nil)
  }

  @MainActor @Test func aSendWithAFileSettlesAgainstItsWordsAndPath() {
    var transcript = ChatTranscript()
    transcript.apply(Self.snapshot)
    transcript.apply([
      "type": "batch", "sessionId": "s",
      "batch": ["cursor": Self.cursor(12), "removedItemIds": [], "submissions": [],
                "items": [Self.item("u2", 12, body: Self.message("user", "look at this\n@\"/tmp/clip.mp4\""))]],
    ])
    var send = PendingSend(id: "op", text: "look at this", attachments: [], state: .sending)
    send.createdAt = 0
    #expect(ChatSessionModel.arrivedWithoutSubmission(send, in: transcript))
    send.text = "look at that"
    #expect(!ChatSessionModel.arrivedWithoutSubmission(send, in: transcript))
  }

  @Test func pagesBackwardsRemovesRowsAndTracksSubmissions() {
    var transcript = ChatTranscript()
    transcript.apply(Self.snapshot)
    transcript.prepend(page: [
      "epoch": "e1", "direction": "before", "hasOlder": false, "hasNewer": true,
      "items": [Self.item("old", 2, body: Self.message("assistant", "earlier"))],
      "removedItemIds": [], "submissions": [],
      "window": ["oldest": Self.cursor(2), "newest": Self.cursor(2), "nextCursor": Self.cursor(2)],
    ])
    #expect(transcript.items.map(\.id) == ["old", "u1", "t1"])
    #expect(!transcript.hasOlder)
    #expect(transcript.oldestCursor?.sequence == 2)
    // Paging back never moves the live resume point.
    #expect(transcript.cursor?.sequence == 11)

    transcript.apply([
      "type": "batch", "sessionId": "s",
      "batch": ["cursor": Self.cursor(14), "items": [], "removedItemIds": ["u1"],
                "submissions": [["clientMessageId": "op-1", "dispatchState": "rejected", "providerItemId": nil, "reason": "busy"]]],
    ])
    #expect(transcript.items.map(\.id) == ["old", "t1"])
    #expect(transcript.submissions["op-1"]?.dispatchState == "rejected")
    #expect(transcript.submissions["op-1"]?.reason == "busy")
  }

  @Test func degradesUnknownShapesAndGatesPrompts() {
    var transcript = ChatTranscript()
    transcript.apply([
      "type": "snapshot", "sessionId": "s", "fence": 1,
      "page": [
        "epoch": "e1", "direction": "tail", "hasOlder": false, "actionablePromptIds": ["ask"],
        "items": [
          Self.item("card", 1, body: ["kind": "automation-saved"]),
          Self.item("ask", 2, body: [
            "kind": "approval", "title": "Run command", "detail": "rm -rf build",
            "options": [["id": "y", "label": "Allow", "intent": "allow_once"], ["id": "n", "label": "Deny", "intent": "reject_once"]],
            "resolution": ["state": "pending", "selectedOptionId": nil],
          ]),
          Self.item("stale", 3, body: [
            "kind": "question", "question": "Which?", "options": [["id": "a", "label": "A"]],
            "resolution": ["state": "pending", "selectedOptionId": nil],
          ]),
          Self.item("tool", 4, body: ["kind": "tool-call", "name": "Bash", "input": ["command": "swift test"], "state": "running"]),
          ["no": "itemId"],
        ],
        "removedItemIds": [], "submissions": [], "window": ["oldest": nil, "newest": nil, "nextCursor": Self.cursor(4)],
      ],
    ])
    #expect(transcript.items.count == 4)
    #expect(transcript.items[0].body == .other(kind: "automation-saved"))
    #expect(transcript.isActionable(transcript.items[1]))
    #expect(!transcript.isActionable(transcript.items[2]))
    guard case .approval(let prompt) = transcript.items[1].body, case .toolCall(let tool) = transcript.items[3].body else {
      Issue.record("unexpected bodies")
      return
    }
    #expect(prompt.options.map(\.isRejection) == [false, true])
    #expect(tool.summary == "swift test")
    #expect(transcript.cursor?.sequence == 4)
  }
}
