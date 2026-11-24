import OrcaCore
import UIKit

/// A catalog snapshot for the compact overlay. It carries only names and confirmed work states.
struct PiPWorkStatus {
  struct Entry {
    let agent: WorkingAgent
    var line: PiPFrame.StatusLine
    let workingChildTypes: [String?]
    let session: PiPAgentTelemetry.Key?

    var id: WorkingAgent.ID { agent.id }
    var activity: WorkingAgent.Activity { agent.activity }
    var workingCount: Int { workingChildTypes.count + (agent.leadActivity == .working ? 1 : 0) }
  }

  let entries: [Entry]
  let hostCount: Int
  let allHostsObserved: Bool

  @MainActor
  init(model: AppModel) {
    var entries: [Entry] = []
    var hostCount = 0
    var observed = 0
    for host in model.orderedHosts {
      guard let session = model.session(for: host.id), session.hasLiveWorktrees else { continue }
      observed += 1
      let agents = WorkingAgent.inCatalog(session.worktrees, host: host.id)
      if !agents.isEmpty { hostCount += 1 }
      for agent in agents {
        // Keep following telemetry on waiting agents too so cumulative tokens remain visible.
        let key = agent.structuredSessionId.map { PiPAgentTelemetry.Key(host: host.id, sessionId: $0) }
        let childTypes = agent.children.filter { $0.activity == .working }.map { child in
          AgentMark.overlayType(for: child.agentType) ?? AgentMark.overlayType(for: child.owningAgentType)
        }
        let line = PiPFrame.StatusLine(
          agent: Self.title(agent), agentType: AgentMark.overlayType(for: agent.agentType),
          isWorker: agent.isWorker, host: Self.oneLine(session.name))
        entries.append(Entry(agent: agent, line: line, workingChildTypes: childTypes, session: key))
      }
    }
    // Disambiguate host subtitles across the full active roster only when the same title spans ≥ 2 hosts.
    let ambiguousTitles = WorkingAgent.crossHostDuplicateTitles(
      in: entries.map { (host: $0.agent.id.host, title: $0.line.agent) })
    let counts = Dictionary(grouping: entries, by: \.line).mapValues(\.count)
    var ordinals: [PiPFrame.StatusLine: Int] = [:]
    let labeled = entries.map { entry in
      var labeled = entry
      labeled.line.showsHostSubtitle = ambiguousTitles.contains(WorkingAgent.normalizedTitleKey(entry.line.agent))
      if counts[entry.line, default: 0] > 1 {
        ordinals[entry.line, default: 0] += 1
        labeled.line.agent = "\(ordinals[entry.line, default: 1]). \(entry.line.agent)"
      }
      return labeled
    }
    self.entries =
      labeled.filter { $0.activity == .needsDecision }
      + labeled.filter { $0.activity == .needsAnswer }
      + labeled.filter { $0.activity == .working }
    self.hostCount = hostCount
    allHostsObserved = observed > 0 && observed == model.hosts.count
  }

  func frame(
    showing visible: [Entry], page: WorkingAgentRotation.Page, paused: Bool = false,
    elapsed: (Entry, Double?) -> String?,
    reading: (Entry) -> (metrics: AgentActivityMetrics.Reading, webSearchStartedAt: TimeInterval?)?
  ) -> PiPFrame {
    let title: String
    let status: String
    if entries.isEmpty {
      title = allHostsObserved
        ? String(localized: "orcaios.pip.noWorkingAgents", defaultValue: "No agents working")
        : String(localized: "orcaios.pip.statusUnavailable", defaultValue: "Agent status unavailable")
      status = ""
    } else {
      title = String.localizedStringWithFormat(
        String(localized: "orcaios.pip.workingAgents", defaultValue: "%lld working"), entries.reduce(0) { $0 + $1.workingCount })
      status = String.localizedStringWithFormat(
        String(localized: "orcaios.pip.workingHosts", defaultValue: "%lld hosts"), hostCount)
    }
    let scrollState: PiPFrame.ScrollState? = entries.count > 2
      ? .init(
        activities: entries.map(\.activity),
        activeIndices: page.indices,
        pinsFirstRow: page.scrollsOnlySecondRow,
        splitAt: page.splitAt,
        isPaused: paused)
      : nil
    return PiPFrame(
      title: title, status: status, working: !entries.isEmpty, lines: [], terminal: false,
      statusRows: visible.map { entry in
        var line = entry.line
        line.activity = entry.activity
        line.leadWorking = entry.agent.leadActivity == .working
        line.childTypes = entry.workingChildTypes
        var turnStartedAt: Double?
        if let (value, webSearchStartedAt) = reading(entry) {
          line.totalTokens = value.totalTokens
          line.tokenCountIsPartial = value.tokenCountIsPartial
          line.toolCount = value.toolCalls.map { (value.toolCountIsPartial ? "≥" : "") + String($0) }
          line.toolRunning = value.toolIsRunning
          line.activeToolKind = value.activeToolKind
          line.webSearchStartedAt = webSearchStartedAt
          turnStartedAt = value.turnStartedAt
        }
        let needsElapsed = line.activity != .working
          ? line.totalTokens == nil
          : (line.totalTokens == nil && line.toolCount == nil)
        if needsElapsed {
          line.elapsedText = elapsed(entry, turnStartedAt)
        }
        return .init(id: entry.id, worktreeId: entry.agent.worktreeId, line: line)
      }, scrollState: scrollState, statusAvailable: allHostsObserved)
  }

  static func formatElapsed(_ seconds: Int, includeSeconds: Bool) -> String? {
    guard seconds >= 1 else { return nil }
    if seconds < 60 {
      return includeSeconds ? "\(seconds)s" : nil
    }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h"
  }

  static func normalizedEpochSeconds(_ raw: Double?, relativeTo now: TimeInterval) -> TimeInterval? {
    guard let raw, raw.isFinite, raw > 0 else { return nil }
    let seconds = raw > 1_000_000_000_000 ? raw / 1000 : raw
    // Reject implausible timestamps (before 2020 or >7 days stale / >5s in future).
    guard seconds > 1_577_836_800 else { return nil }
    let age = now - seconds
    guard age >= -5, age < 86_400 * 7 else { return nil }
    return seconds
  }

  private static func title(_ agent: WorkingAgent) -> String {
    let name = oneLine(agent.name ?? agent.workspace)
    return name.isEmpty ? String(localized: "session.backgroundTask.agent", defaultValue: "Agent") : name
  }

  private static func oneLine(_ value: String) -> String {
    value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}

struct PiPWebSearchIndicator {
  private static let displayDuration: TimeInterval = 2
  private static let cycleDuration: TimeInterval = 3
  private static let transitionDuration: TimeInterval = 0.25

  private var latestCallID: String?
  private var startedAt: TimeInterval?
  private var pending = false

  /// Record searches already present in a journal snapshot without replaying them.
  mutating func seed(latestCallID: String?) {
    self.latestCallID = latestCallID
    pending = false
  }

  mutating func pulseStart(for reading: AgentActivityMetrics.Reading, at time: TimeInterval) -> TimeInterval? {
    guard reading.toolCalls != nil else { return nil }
    let elapsed = startedAt.map { time - $0 } ?? .infinity
    if let callID = reading.latestWebSearchCallID {
      if callID != latestCallID, elapsed >= Self.displayDuration { pending = true }
    } else {
      pending = false
    }
    latestCallID = reading.latestWebSearchCallID
    if elapsed >= Self.cycleDuration, pending || reading.webSearchIsRunning {
      startedAt = time
      pending = false
      return time
    }
    return elapsed < Self.displayDuration ? startedAt : nil
  }

  static func globeOpacity(startedAt: TimeInterval?, at time: TimeInterval, animated: Bool) -> CGFloat {
    guard let startedAt else { return 0 }
    let elapsed = time - startedAt
    guard elapsed >= 0, elapsed < displayDuration else { return 0 }
    guard animated else { return 1 }
    let edge = min(elapsed, displayDuration - elapsed)
    let progress = CGFloat(min(edge / transitionDuration, 1))
    return progress * progress * (3 - 2 * progress)
  }
}

/// Shares one subscription among all visible producers of a session. The next page is warmed up while the current one is shown.
@MainActor
final class PiPAgentTelemetry {
  struct Key: Hashable {
    let host: UUID
    let sessionId: String
  }

  private final class Stream {
    let connection: OrcaConnection
    var metrics = AgentActivityMetrics()
    var webSearch = PiPWebSearchIndicator()
    var task: Task<Void, Never>?
    private var catchingUp = false
    private var hadSnapshot = false

    init(connection: OrcaConnection) { self.connection = connection }

    func apply(_ frame: JSONValue) -> Bool {
      let before = metrics.reading(agentId: nil, includeChildTokenFloor: true)
      metrics.apply(frame)
      var shouldNotify = false
      switch frame["type"]?.stringValue {
      case "snapshot", "reset":
        catchingUp = frame["page"]?["hasNewer"]?.boolValue == true
        seedWebSearch()
        if !catchingUp && !hadSnapshot {
          hadSnapshot = true
          shouldNotify = true
        }
      case "batch":
        let wasCatchingUp = catchingUp
        catchingUp = frame["hasNewer"]?.boolValue == true
        if wasCatchingUp, !catchingUp {
          seedWebSearch()
          hadSnapshot = true
          shouldNotify = true
        }
      default:
        break
      }
      if !shouldNotify, !catchingUp {
        let after = metrics.reading(agentId: nil, includeChildTokenFloor: true)
        if before.toolIsRunning != after.toolIsRunning || before.activeToolKind != after.activeToolKind {
          shouldNotify = true
        }
      }
      return shouldNotify
    }

    private func seedWebSearch() {
      webSearch.seed(latestCallID: metrics.reading(agentId: nil).latestWebSearchCallID)
    }
  }

  private var streams: [Key: Stream] = [:]
  var onUpdate: (() -> Void)?

  func follow(_ targets: Set<Key>, model: AppModel) {
    for key in Array(streams.keys) where !targets.contains(key) || model.session(for: key.host)?.api.connection !== streams[key]?.connection {
      streams.removeValue(forKey: key)?.task?.cancel()
    }
    for key in targets where streams[key] == nil {
      guard let api = model.session(for: key.host)?.api else { continue }
      let stream = Stream(connection: api.connection)
      streams[key] = stream
      stream.task = Task { [weak self, weak stream] in
        var delay = Duration.seconds(1)
        while !Task.isCancelled {
          let subscription = await api.chat(sessionId: key.sessionId, resumingFrom: nil)
          var retry = true
          do {
            for try await frame in subscription.events {
              guard !Task.isCancelled else { break }
              if stream?.apply(frame) == true {
                self?.onUpdate?()
              }
              if frame["type"]?.stringValue == "end" { break }
              delay = .seconds(1)
            }
          } catch let error as RPCError {
            retry = !["method_not_found", "forbidden", "invalid_argument"].contains(error.code)
          } catch {
            // Retry if a stream ended unexpectedly. The connection itself reopens after a dropped socket.
          }
          await api.connection.unsubscribe(subscription.requestId)
          stream?.metrics = AgentActivityMetrics()
          guard retry, !Task.isCancelled, (try? await Task.sleep(for: delay)) != nil else { return }
          delay = min(delay * 2, .seconds(10))
        }
      }
    }
  }

  func reading(
    _ entry: PiPWorkStatus.Entry, at time: TimeInterval
  ) -> (metrics: AgentActivityMetrics.Reading, webSearchStartedAt: TimeInterval?)? {
    guard let key = entry.session, let stream = streams[key] else { return nil }
    let metrics = stream.metrics.reading(agentId: nil, includeChildTokenFloor: true)
    let webSearchStartedAt = stream.webSearch.pulseStart(for: metrics, at: time)
    return (metrics, webSearchStartedAt)
  }
}
