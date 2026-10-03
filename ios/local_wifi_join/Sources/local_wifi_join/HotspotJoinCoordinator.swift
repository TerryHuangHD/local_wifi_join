import Foundation
import NetworkExtension

/// The reply sent to Dart for one `join` call.
struct JoinOutcome: Equatable {
  let status: String
  var platformCode: String?
  var message: String?

  static let joined = JoinOutcome(status: "joined")
  static let timeout = JoinOutcome(status: "timeout")
  static let cancelled = JoinOutcome(status: "cancelled")

  static func invalidArguments(_ message: String) -> JoinOutcome {
    JoinOutcome(status: "invalidArguments", message: message)
  }

  var isJoined: Bool { status == JoinOutcome.joined.status }

  var asDictionary: [String: Any] {
    [
      "status": status,
      "platformCode": platformCode ?? NSNull(),
      "message": message ?? NSNull(),
    ]
  }
}

extension JoinOutcome {
  /// Maps the completion error of `NEHotspotConfigurationManager.apply`.
  ///
  /// Only the error is inspected. The current SSID is deliberately not read back
  /// (`NEHotspotNetwork.fetchCurrent` is refused by nehelper on iOS 26+), so
  /// `joined` means "configuration accepted", not "associated".
  init(applyError error: Error?) {
    guard let error = error as NSError? else {
      self = .joined
      return
    }
    guard error.domain == NEHotspotConfigurationErrorDomain else {
      self.init(
        status: "failed",
        platformCode: "\(error.domain)(\(error.code))",
        message: error.localizedDescription
      )
      return
    }
    let status: String
    switch NEHotspotConfigurationError(rawValue: error.code) {
    case .alreadyAssociated:
      status = "joined"
    case .userDenied:
      status = "userDenied"
    case .applicationIsNotInForeground:
      status = "notInForeground"
    case .invalid, .invalidSSID, .invalidWPAPassphrase, .invalidWEPPassphrase,
      .invalidEAPSettings, .invalidHS20Settings, .invalidHS20DomainName, .invalidSSIDPrefix:
      status = "invalidArguments"
    default:
      status = "failed"
    }
    self.init(
      status: status,
      platformCode: Self.hotspotErrorName(error.code),
      message: error.localizedDescription
    )
  }

  /// `NEHotspotConfigurationError` case names, indexed by raw value.
  private static let hotspotErrorNames = [
    "invalid", "invalidSSID", "invalidWPAPassphrase", "invalidWEPPassphrase",
    "invalidEAPSettings", "invalidHS20Settings", "invalidHS20DomainName", "userDenied",
    "internal", "pending", "systemConfiguration", "unknown", "joinOnceNotSupported",
    "alreadyAssociated", "applicationIsNotInForeground", "invalidSSIDPrefix",
    "userUnauthorized", "systemDenied",
  ]

  private static func hotspotErrorName(_ code: Int) -> String {
    hotspotErrorNames.indices.contains(code)
      ? hotspotErrorNames[code] : "\(NEHotspotConfigurationErrorDomain)(\(code))"
  }
}

/// Handle that cancels scheduled work. Cancelling twice is harmless.
protocol TimerHandle {
  func cancel()
}

/// Schedules work on the main queue.
protocol MainScheduler {
  func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> TimerHandle
}

/// The `NEHotspotConfigurationManager` operations used by `HotspotJoinCoordinator`.
protocol HotspotConfigurator {
  func removeConfiguration(forSSID ssid: String)

  /// Applies a `joinOnce` WPA2-Personal configuration. `completion` runs on the main queue.
  func applyJoinOnce(ssid: String, passphrase: String, completion: @escaping (Error?) -> Void)
}

/// Main-queue state machine behind `join` and `leave`.
///
/// Invariants:
/// - Every `join` reply is delivered exactly once.
/// - Any configuration left by an earlier session for the SSID is removed before applying,
///   and the apply waits `removeDelay` because `removeConfiguration` has no completion.
/// - At most one `apply` is in flight. A join whose delay has elapsed waits for the previous
///   apply to complete, so iOS never sees overlapping applies (which fail with `pending`).
/// - A join that ends without `joined` (timeout, cancel, dispose) removes its configuration,
///   including one that a still-in-flight `apply` installs afterwards. The in-flight apply
///   retains the coordinator, so this also happens after the plugin is released.
final class HotspotJoinCoordinator {
  private final class Session {
    let ssid: String
    let passphrase: String
    let removeDelay: TimeInterval
    var reply: ((JoinOutcome) -> Void)?
    var timeoutTimer: TimerHandle?
    var delayTimer: TimerHandle?
    /// Whether `removeDelay` has passed since the last removal for `ssid`.
    var delayElapsed = false

    init(
      ssid: String, passphrase: String, removeDelay: TimeInterval,
      reply: @escaping (JoinOutcome) -> Void
    ) {
      self.ssid = ssid
      self.passphrase = passphrase
      self.removeDelay = removeDelay
      self.reply = reply
    }
  }

  private let configurator: HotspotConfigurator
  private let scheduler: MainScheduler
  private var pending: Session?
  private var applyInFlight = false
  /// SSIDs whose configuration was applied successfully and not left since.
  private var joinedSSIDs = Set<String>()

  init(configurator: HotspotConfigurator, scheduler: MainScheduler) {
    self.configurator = configurator
    self.scheduler = scheduler
  }

  func join(
    ssid: String,
    passphrase: String,
    timeout: TimeInterval,
    removeDelay: TimeInterval,
    reply: @escaping (JoinOutcome) -> Void
  ) {
    cancelPending()

    let session = Session(
      ssid: ssid, passphrase: passphrase, removeDelay: removeDelay, reply: reply)
    pending = session
    joinedSSIDs.remove(ssid)
    configurator.removeConfiguration(forSSID: ssid)
    session.timeoutTimer = scheduler.schedule(after: timeout) { [weak self] in
      self?.timeOut(session)
    }
    startRemoveDelay(session)
  }

  /// Cancels a pending join and removes the configuration for `ssid`. Idempotent.
  func leave(ssid: String) {
    cancelPending()
    joinedSSIDs.remove(ssid)
    configurator.removeConfiguration(forSSID: ssid)
  }

  /// Cancels a pending join and removes every configuration this coordinator installed,
  /// for when the engine goes away.
  func dispose() {
    cancelPending()
    joinedSSIDs.forEach(configurator.removeConfiguration(forSSID:))
    joinedSSIDs.removeAll()
  }

  /// (Re)starts the wait between removing `session.ssid`'s configuration and applying it.
  private func startRemoveDelay(_ session: Session) {
    session.delayElapsed = false
    session.delayTimer?.cancel()
    session.delayTimer = scheduler.schedule(after: session.removeDelay) { [weak self] in
      session.delayElapsed = true
      self?.applyIfReady()
    }
  }

  private func applyIfReady() {
    guard let session = pending, session.delayElapsed, !applyInFlight else { return }
    applyInFlight = true
    // Strong capture: a late success must be undone even if the plugin has been released.
    configurator.applyJoinOnce(ssid: session.ssid, passphrase: session.passphrase) { error in
      self.applyCompleted(session, error: error)
    }
  }

  private func applyCompleted(_ session: Session, error: Error?) {
    applyInFlight = false
    let outcome = JoinOutcome(applyError: error)
    guard pending === session else {
      // The join already ended while `apply` was in flight: don't let a configuration it
      // installed anyway take effect. A waiting join cannot have applied yet, so this never
      // removes a newer configuration.
      if outcome.isJoined {
        configurator.removeConfiguration(forSSID: session.ssid)
        if let next = pending, next.ssid == session.ssid {
          startRemoveDelay(next)
          return
        }
      }
      applyIfReady()
      return
    }
    pending = nil
    if outcome.isJoined {
      joinedSSIDs.insert(session.ssid)
    }
    finish(session, outcome)
  }

  private func timeOut(_ session: Session) {
    guard pending === session else { return }
    pending = nil
    configurator.removeConfiguration(forSSID: session.ssid)
    finish(session, .timeout)
  }

  private func cancelPending() {
    guard let session = pending else { return }
    pending = nil
    configurator.removeConfiguration(forSSID: session.ssid)
    finish(session, .cancelled)
  }

  private func finish(_ session: Session, _ outcome: JoinOutcome) {
    session.timeoutTimer?.cancel()
    session.delayTimer?.cancel()
    session.timeoutTimer = nil
    session.delayTimer = nil
    guard let reply = session.reply else { return }
    session.reply = nil
    reply(outcome)
  }
}
