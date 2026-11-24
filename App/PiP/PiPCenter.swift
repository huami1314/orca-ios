import AVFoundation
import AVKit
import Observation
import OrcaCore
import UIKit

/// A session transcript or a status snapshot of the paired hosts.
struct PiPFrame: Equatable {
  enum Style: Equatable { case body, muted, call, terminal }
  struct StatusLine: Hashable {
    var agent: String
    let agentType: String?
    let isWorker: Bool
    let host: String
    var showsHostSubtitle = false
    var activity: WorkingAgent.Activity = .working
    var leadWorking = false
    var childTypes: [String?] = []
    var totalTokens: Int?
    var tokenCountIsPartial = false
    var toolCount: String?
    var toolRunning = false
    var activeToolKind: TranscriptItem.ToolCall.ActivityKind?
    var webSearchStartedAt: TimeInterval?
    var elapsedText: String?

    var showsChildStackSpinner: Bool { activity == .working && !leadWorking && !childTypes.isEmpty }
    var showsWorkingSpinner: Bool { activity == .working && (leadWorking || !childTypes.isEmpty) }
  }
  struct ScrollState: Equatable {
    let activities: [WorkingAgent.Activity]
    let activeIndices: [Int]
    let pinsFirstRow: Bool
    let splitAt: Int?
    let isPaused: Bool
  }
  struct StatusRow: Equatable {
    let id: WorkingAgent.ID
    let worktreeId: String
    let line: StatusLine
  }

  var title: String
  var status: String
  var working: Bool
  var lines: [(text: String, style: Style)]
  /// A terminal's frame: monospaced on the terminal's ground.
  var terminal: Bool
  var statusRows: [StatusRow] = []
  var scrollState: ScrollState?
  var statusAvailable = true

  static func == (a: PiPFrame, b: PiPFrame) -> Bool {
    a.title == b.title && a.status == b.status && a.working == b.working
      && a.terminal == b.terminal && a.statusRows == b.statusRows && a.scrollState == b.scrollState
      && a.statusAvailable == b.statusAvailable
      && a.lines.elementsEqual(b.lines) { $0.text == $1.text && $0.style == $1.style }
  }
}

struct PiPScrollTransition: Equatable {
  enum Kind: Equatable {
    case full(leaving: PiPFrame.StatusLine)
    case perRow(leavingFirst: PiPFrame.StatusLine?, leavingSecond: PiPFrame.StatusLine?)
    /// 1 -> 2: single expanded hero contracts smoothly into its target compact row while the second enters.
    case expandToTwo(wasRowIndex: Int)
    /// 2 -> 1: the departing compact row fades away while the surviving row expands into the 60pt hero card.
    case collapseToOne(departing: PiPFrame.StatusLine, departingRowIndex: Int)
  }
  let kind: Kind
  let fromScroll: PiPFrame.ScrollState?
  let direction: Int

  init(kind: Kind, fromScroll: PiPFrame.ScrollState?, direction: Int = 1) {
    self.kind = kind
    self.fromScroll = fromScroll
    self.direction = direction
  }
}

enum PiPLayout {
  case transcript, compact

  var size: CGSize {
    switch self {
    case .transcript: CGSize(width: 400, height: 300)
    case .compact: CGSize(width: 400, height: 68)
    }
  }
}

/// Keeps the app's host connections open while picture in picture is on screen.
@MainActor
final class PiPCenter: NSObject {
  static let shared = PiPCenter()

  /// Leaving the app opens picture in picture when the selected layout has active work.
  static var startsOnLeave: Bool {
    get { UserDefaults.standard.object(forKey: "orca.pip.auto") as? Bool ?? true }
    set {
      UserDefaults.standard.set(newValue, forKey: "orca.pip.auto")
      shared.updateAutoStart()
    }
  }

  /// A chat in the window lists each command; off, a run of them reads as one line, as in the chat.
  static var showsCommands: Bool {
    get { UserDefaults.standard.bool(forKey: "orca.pip.commands") }
    set {
      UserDefaults.standard.set(newValue, forKey: "orca.pip.commands")
      shared.draw(force: true)
    }
  }

  static var usesCompactLayout: Bool {
    get { UserDefaults.standard.bool(forKey: "orca.pip.compact") }
    set {
      UserDefaults.standard.set(newValue, forKey: "orca.pip.compact")
      shared.refreshAttachment()
    }
  }

  private static var layout: PiPLayout { usesCompactLayout ? .compact : .transcript }

  /// Launch with ORCA_DEBUG_PIP=1 to write the frame the window would show to tmp/pip.png, every second
  /// (the simulator has no picture in picture to look at).
  private func dumpForDebugging() {
    guard ProcessInfo.processInfo.environment["ORCA_DEBUG_PIP"] == "1", debugTimer == nil else { return }
    debugTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let frame = self?.last ?? self?.frame()?.content else { return }
        let image = PiPRenderer.image(for: frame, layout: Self.layout)
        try? image.pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("pip.png"))
      }
    }
  }
  private var debugTimer: Timer?

  private let host = UIView()
  private let layer = AVSampleBufferDisplayLayer()
  private weak var compactHost: UIView?
  private weak var sessionHost: UIView?
  private var transcriptFrame: (() -> PiPFrame?)?
  private var workStatus: PiPWorkStatus?
  private var rotation = WorkingAgentRotation()
  private var waitingAgents: Set<WorkingAgent.ID> = []
  private var activitySince: [WorkingAgent.ID: (activity: WorkingAgent.Activity, uptime: TimeInterval)] = [:]
  private var lastPresentedAttention: (host: UUID, worktreeId: String)?
  private var lastPresentedRow: (host: UUID, worktreeId: String)?
  private let telemetry = PiPAgentTelemetry()
  private var controller: AVPictureInPictureController?
  private var timer: Timer?
  private var animationTimer: Timer?
  private var last: PiPFrame?
  private var lastLayout: PiPLayout?
  private var transition: Task<Void, Never>?
  private var lastDrawn = Date.distantPast
  private let silence = SilentAudio()
  private(set) var isActive = false
  private var rotationPaused = false
  private var pendingStep = 0
  /// The system starts picture in picture on leaving only from media that plays; idle, the frames read as
  /// paused, so nothing opens. Read from the playback delegate, off the main actor.
  nonisolated(unsafe) private static var playing = false
  /// True when the mini status bar has >2 active groups so PiP skip buttons can step backward/forward.
  nonisolated(unsafe) private static var skippable = false
  /// The window was opened from the session menu: it stays even while idle.
  private var openedByHand = false

  var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

  func attachCompact(to view: UIView) {
    compactHost = view
    refreshAttachment()
  }

  func attachTranscript(to view: UIView, source: @escaping () -> PiPFrame?) {
    sessionHost = view
    transcriptFrame = source
    if !Self.usesCompactLayout { refreshAttachment() }
  }

  func detachTranscript(from view: UIView) {
    guard sessionHost === view, !isActive || Self.usesCompactLayout else { return }
    sessionHost = nil
    transcriptFrame = nil
    if !Self.usesCompactLayout { refreshAttachment() }
  }

  /// The source layer must be in the live window for iOS to offer picture in picture.
  private func refreshAttachment() {
    dumpForDebugging()
    if telemetry.onUpdate == nil {
      telemetry.onUpdate = { [weak self] in
        guard let self, self.isActive, Self.usesCompactLayout else { return }
        self.draw(force: false)
      }
    }
    if !Self.usesCompactLayout || compactHost == nil { telemetry.follow([], model: AppModel.shared) }
    guard isSupported else { return }
    guard let view = Self.usesCompactLayout ? compactHost : sessionHost else {
      host.removeFromSuperview()
      cancelTransition()
      timer?.invalidate()
      timer = nil
      setAnimatingFrames(false)
      last = nil
      lastLayout = nil
      updateAutoStart()
      return
    }
    host.isUserInteractionEnabled = false
    host.alpha = 1
    host.frame = view.bounds
    host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    layer.frame = host.bounds
    layer.videoGravity = .resizeAspect
    if layer.superlayer == nil { host.layer.addSublayer(layer) }
    if host.superview !== view { view.insertSubview(host, at: 0) }
    if controller == nil {
      let content = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
      let controller = AVPictureInPictureController(contentSource: content)
      controller.delegate = self
      controller.requiresLinearPlayback = true
      self.controller = controller
    }
    if timer == nil { startTimer(interval: 1) }
    draw(force: true)
  }

  private func frame() -> (content: PiPFrame, didAdvance: Bool, stepDirection: Int, scrollsOnlySecondRow: Bool, isSplit: Bool)? {
    guard Self.usesCompactLayout else {
      pendingStep = 0
      guard let transcript = transcriptFrame?() else { return nil }
      return (transcript, false, 0, false, false)
    }
    let status: PiPWorkStatus
    if let workStatus {
      status = workStatus
    } else {
      status = withObservationTracking {
        PiPWorkStatus(model: AppModel.shared)
      } onChange: { [weak self] in
        Task { @MainActor in
          self?.workStatus = nil
          if Self.usesCompactLayout { self?.draw(force: false) }
        }
      }
      workStatus = status
    }
    let time = ProcessInfo.processInfo.systemUptime
    let nowEpoch = Date().timeIntervalSince1970
    let activeIDs = Set(status.entries.map(\.id))
    activitySince = activitySince.filter { activeIDs.contains($0.key) }
    for entry in status.entries where activitySince[entry.id]?.activity != entry.activity {
      activitySince[entry.id] = (entry.activity, time)
    }
    let manualStep = pendingStep
    pendingStep = 0
    let waiting = status.entries.filter { $0.activity != .working }.map(\.id)
    let newlyWaiting = waiting.first { !waitingAgents.contains($0) }
    waitingAgents = Set(waiting)
    let pinned = waiting.count == 1 && status.entries.count > 2 ? waiting.first : nil
    let splitAt = waiting.count >= 2 && waiting.count < status.entries.count ? waiting.count : nil
    let page = rotation.page(
      in: status.entries.map(\.id), at: time, rotating: isActive && !rotationPaused,
      preferring: pinned == nil ? newlyWaiting : nil, pinned: pinned, splitAt: splitAt, step: manualStep)
    let entries = page.indices.map { status.entries[$0] }
    if isActive {
      var targets = Set(entries.compactMap(\.session))
      if let next = page.nextIndex, let key = status.entries[next].session { targets.insert(key) }
      if let secondaryNext = page.secondaryNextIndex, let key = status.entries[secondaryNext].session { targets.insert(key) }
      telemetry.follow(targets, model: AppModel.shared)
    }
    let includeSeconds = isActive
    return (
      status.frame(showing: entries, page: page, paused: rotationPaused, elapsed: { entry, turnStartedAt in
        let seconds: Int?
        if entry.activity == .working, let start = PiPWorkStatus.normalizedEpochSeconds(turnStartedAt, relativeTo: nowEpoch) {
          seconds = max(0, Int(nowEpoch - start))
        } else if let updated = PiPWorkStatus.normalizedEpochSeconds(entry.agent.updatedAt, relativeTo: nowEpoch) {
          seconds = max(0, Int(nowEpoch - updated))
        } else if let since = activitySince[entry.id]?.uptime {
          seconds = max(0, Int(time - since))
        } else {
          seconds = nil
        }
        return seconds.flatMap { PiPWorkStatus.formatElapsed($0, includeSeconds: includeSeconds) }
      }, reading: { telemetry.reading($0, at: time) }),
      page.didAdvance,
      page.stepDirection,
      page.scrollsOnlySecondRow,
      page.splitAt != nil
    )
  }

  /// Another feature (dictation) took the audio session and let it go: play again so leaving the app still
  /// opens picture in picture.
  func reclaimAudio() {
    guard host.superview != nil else { return }
    silence.stop()
    updateAutoStart()
  }

  /// Leaving opens the window only while the agent is working: there is nothing to watch otherwise.
  private func updateAutoStart() {
    let working = last?.working ?? false
    let attached = host.superview != nil
    let wanted = attached && Self.startsOnLeave && working
    if controller?.canStartPictureInPictureAutomaticallyFromInline != wanted {
      controller?.canStartPictureInPictureAutomaticallyFromInline = wanted
    }
    // Enable PiP skip buttons only when the mini status bar has extra rows to flip through.
    let canSkip = Self.usesCompactLayout && ((last?.scrollState?.activities.count ?? 0) > 2)
    let needsLinear = !canSkip
    if controller?.requiresLinearPlayback != needsLinear {
      controller?.requiresLinearPlayback = needsLinear
    }
    let skipChanged = Self.skippable != canSkip
    Self.skippable = canSkip
    // While inactive, playing signals auto-start on leave. While active in mini status bar,
    // playing reflects whether auto-rotation is running (pause pins the visible pair).
    let playing = isActive && Self.usesCompactLayout ? !rotationPaused : (openedByHand || wanted)
    if Self.playing != playing || skipChanged {
      Self.playing = playing
      controller?.invalidatePlaybackState()
    }
    // Keep an open overlay updating (including while rotation is paused).
    if attached && (isActive || playing || !Self.usesCompactLayout) { silence.start() } else { silence.stop() }
  }

  private func setRotationPaused(_ paused: Bool) {
    guard isActive, Self.usesCompactLayout, rotationPaused != paused else { return }
    rotationPaused = paused
    updateAutoStart()
    draw(force: true)
  }

  private func stepRotation(_ delta: Int) {
    guard isActive, Self.usesCompactLayout, delta != 0 else { return }
    pendingStep = delta > 0 ? 1 : -1
    draw(force: true)
  }

  /// The app is about to go: decide from what is on screen right now, not the last frame drawn.
  func appWillResignActive() {
    guard host.superview != nil else { return }
    draw(force: true)
    updateAutoStart()
  }

  /// Back in the app, the window goes: the session it showed is on screen again.
  func appBecameActive() {
    guard isActive else { return }
    controller?.stopPictureInPicture()
  }

  func start() {
    guard host.superview != nil else { return }
    openedByHand = true
    updateAutoStart()
    draw(force: true)
    controller?.startPictureInPicture()
  }

  func stop() {
    controller?.stopPictureInPicture()
  }

  private func startTimer(interval: TimeInterval) {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
      MainActor.assumeIsolated { PiPCenter.shared.draw(force: false) }
    }
  }

  /// Redraw the current frame without polling agent telemetry or advancing the rows.
  private func setAnimatingFrames(_ animating: Bool) {
    if !animating {
      animationTimer?.invalidate()
      animationTimer = nil
      return
    }
    guard animationTimer == nil else { return }
    let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.transition == nil, let frame = self.last,
          self.layer.sampleBufferRenderer.isReadyForMoreMediaData
        else { return }
        self.enqueue(frame, layout: .compact)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    animationTimer = timer
  }

  /// Draws a new frame when the content changed, and at least every few seconds so the layer stays live.
  private func draw(force: Bool) {
    guard host.superview != nil else { return }
    guard let (frame, didAdvance, stepDirection, scrollsOnlySecondRow, isSplit) = frame() else {
      setAnimatingFrames(false)
      if last != nil {
        last = nil
        cancelTransition()
        layer.flushAndRemoveImage()
      }
      updateAutoStart()
      return
    }
    let layout = Self.layout
    if isActive, layout == .compact {
      if let attention = frame.statusRows.first(where: { $0.line.activity != .working }) {
        lastPresentedAttention = (attention.id.host, attention.worktreeId)
      } else {
        lastPresentedAttention = nil
      }
      if let first = frame.statusRows.first {
        lastPresentedRow = (first.id.host, first.worktreeId)
      } else {
        lastPresentedRow = nil
      }
    }
    let animate = isActive && !UIAccessibility.isReduceMotionEnabled && layout == .compact
    let shouldAnimateFrames = animate && frame.statusRows.contains { row in
      row.line.showsWorkingSpinner || (row.line.activity == .working && row.line.webSearchStartedAt != nil)
    }
    let animationChanged = shouldAnimateFrames != (animationTimer != nil)
    let now = Date()
    guard force || frame != last || layout != lastLayout || animationChanged || now.timeIntervalSince(lastDrawn) > 4 else { return }
    let previous = layout == .compact && lastLayout == .compact ? last?.statusRows : nil
    let previousScroll = layout == .compact && lastLayout == .compact ? last?.scrollState : nil
    if lastLayout != layout { layer.flushAndRemoveImage() }
    last = frame
    lastLayout = layout
    lastDrawn = now
    setAnimatingFrames(shouldAnimateFrames)
    updateAutoStart()
    // Update telemetry during the animation without interrupting the rows that are already moving.
    if animate, transition != nil, previous?.map(\.id) == frame.statusRows.map(\.id) { return }
    cancelTransition()
    if animate, let previous {
      if previous.count == 1, frame.statusRows.count == 2,
        let survivedIndex = frame.statusRows.firstIndex(where: { $0.id == previous[0].id }) {
        scroll(.init(kind: .expandToTwo(wasRowIndex: survivedIndex), fromScroll: previousScroll), duration: 0.28)
        return
      }
      if previous.count == 2, frame.statusRows.count == 1,
        let survivedIndex = previous.firstIndex(where: { $0.id == frame.statusRows[0].id }) {
        let departingIndex = survivedIndex == 0 ? 1 : 0
        scroll(
          .init(
            kind: .collapseToOne(departing: previous[departingIndex].line, departingRowIndex: departingIndex),
            fromScroll: previousScroll),
          duration: 0.28)
        return
      }
    }
    if animate, didAdvance, let previous, previous.count == 2, frame.statusRows.count == 2 {
      let dir = stepDirection < 0 ? -1 : 1
      if scrollsOnlySecondRow, previous[0].id == frame.statusRows[0].id, previous[1].id != frame.statusRows[1].id {
        scroll(.init(kind: .perRow(leavingFirst: nil, leavingSecond: previous[1].line), fromScroll: previousScroll, direction: dir))
        return
      }
      if isSplit {
        let leavingFirst = previous[0].id != frame.statusRows[0].id ? previous[0].line : nil
        let leavingSecond = previous[1].id != frame.statusRows[1].id ? previous[1].line : nil
        if leavingFirst != nil || leavingSecond != nil {
          scroll(.init(kind: .perRow(leavingFirst: leavingFirst, leavingSecond: leavingSecond), fromScroll: previousScroll, direction: dir))
          return
        }
      }
      if !scrollsOnlySecondRow, !isSplit {
        if dir > 0, previous[1].id == frame.statusRows[0].id {
          scroll(.init(kind: .full(leaving: previous[0].line), fromScroll: previousScroll, direction: 1))
          return
        }
        if dir < 0, previous[0].id == frame.statusRows[1].id {
          scroll(.init(kind: .full(leaving: previous[1].line), fromScroll: previousScroll, direction: -1))
          return
        }
      }
    }
    enqueue(frame, layout: layout)
  }

  private func cancelTransition() {
    transition?.cancel()
    transition = nil
  }

  private func scroll(_ scrollTransition: PiPScrollTransition, duration: TimeInterval = 0.3) {
    transition = Task { [weak self] in
      let start = ProcessInfo.processInfo.systemUptime
      while !Task.isCancelled, let self, let frame = last {
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let progress = min(CGFloat(elapsed / duration), 1)
        enqueue(frame, layout: .compact, transition: scrollTransition, progress: progress)
        if progress == 1 {
          transition = nil
          return
        }
        if (try? await Task.sleep(for: .milliseconds(33))) == nil { return }
      }
    }
  }

  private func enqueue(
    _ frame: PiPFrame, layout: PiPLayout, transition: PiPScrollTransition? = nil, progress: CGFloat = 1
  ) {
    let time = ProcessInfo.processInfo.systemUptime
    let animateSpinners = isActive && layout == .compact && !UIAccessibility.isReduceMotionEnabled
    let spinnerAngle: CGFloat = animateSpinners
      ? CGFloat(time.truncatingRemainder(dividingBy: 0.9) / 0.9) * 2 * .pi
      : 0
    let childSpinnerAngle: CGFloat = animateSpinners
      ? CGFloat(time.truncatingRemainder(dividingBy: 1.25) / 1.25) * 2 * .pi
      : 0
    guard let buffer = PiPRenderer.sampleBuffer(
      for: frame, layout: layout, transition: transition, progress: progress,
      spinnerAngle: spinnerAngle, childSpinnerAngle: childSpinnerAngle, at: time)
    else { return }
    if layer.status == .failed { layer.flush() }
    layer.enqueue(buffer)
  }
}

extension PiPCenter: AVPictureInPictureControllerDelegate {
  nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    MainActor.assumeIsolated {
      isActive = true
      updateAutoStart()
      startTimer(interval: 0.5)
      // Opened on its own when it shouldn't have (the setting is off, or nothing runs): close it again.
      if !openedByHand, !Self.startsOnLeave || !(last?.working ?? false) {
        controller.stopPictureInPicture()
      } else {
        draw(force: true)
      }
    }
  }

  nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    MainActor.assumeIsolated {
      isActive = false
      rotationPaused = false
      pendingStep = 0
      telemetry.follow([], model: AppModel.shared)
      cancelTransition()
      setAnimatingFrames(false)
      openedByHand = false
      lastPresentedAttention = nil
      lastPresentedRow = nil
      PiPRenderer.clearCache()
      updateAutoStart()
      if host.superview != nil { startTimer(interval: 1) }
    }
  }

  nonisolated func pictureInPictureController(
    _ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error
  ) {
    MainActor.assumeIsolated {
      openedByHand = false
      updateAutoStart()
    }
  }

  nonisolated func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void
  ) {
    MainActor.assumeIsolated {
      if Self.usesCompactLayout, let target = lastPresentedAttention ?? lastPresentedRow {
        var components = URLComponents()
        components.scheme = "orca"
        components.host = "open"
        components.queryItems = [
          URLQueryItem(name: "host", value: target.host.uuidString),
          URLQueryItem(name: "worktree", value: target.worktreeId),
        ]
        if let url = components.url {
          NotificationCenter.default.post(name: .orcaOpenURL, object: url)
        }
      }
      completion(true)
    }
  }
}

extension PiPCenter: AVPictureInPictureSampleBufferPlaybackDelegate {
  nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
    Task { @MainActor in
      self.setRotationPaused(!playing)
    }
  }

  /// Unbounded when >2 active groups can be stepped manually in both directions; otherwise standard live range.
  nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
    Self.skippable
      ? CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
      : CMTimeRange(start: .zero, duration: .positiveInfinity)
  }

  nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
    !PiPCenter.playing
  }

  nonisolated func pictureInPictureController(
    _ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  nonisolated func pictureInPictureController(
    _ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void
  ) {
    let seconds = CMTimeGetSeconds(skipInterval)
    Task { @MainActor in
      if Self.usesCompactLayout, self.isActive, seconds.isFinite, seconds != 0 {
        self.stepRotation(seconds > 0 ? 1 : -1)
      }
      completion()
    }
  }
}

/// A silent, mixable playback session: the system keeps an app that plays running in the background, which
/// keeps the picture-in-picture window and the desktop connection live. Other audio keeps playing.
private final class SilentAudio {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var running = false

  func start() {
    guard !running else { return }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
      try session.setActive(true)
      let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
      if player.engine == nil {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
      }
      engine.mainMixerNode.outputVolume = 0
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
      buffer.frameLength = buffer.frameCapacity
      try engine.start()
      player.scheduleBuffer(buffer, at: nil, options: .loops)
      player.play()
      running = true
    } catch {
      running = false
    }
  }

  func stop() {
    guard running else { return }
    player.stop()
    engine.stop()
    running = false
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}
