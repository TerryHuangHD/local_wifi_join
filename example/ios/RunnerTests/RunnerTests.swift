import NetworkExtension
import XCTest

@testable import local_wifi_join

// Unit tests for the plugin's join state machine, using fakes instead of
// NEHotspotConfigurationManager. Run from Xcode or with:
//   xcodebuild test -workspace Runner.xcworkspace -scheme Runner \
//     -destination 'platform=iOS Simulator,name=<simulator>'

private final class FakeTimer: TimerHandle {
  let dueAt: TimeInterval
  let work: () -> Void
  var cancelled = false

  init(dueAt: TimeInterval, work: @escaping () -> Void) {
    self.dueAt = dueAt
    self.work = work
  }

  func cancel() { cancelled = true }
}

private final class FakeScheduler: MainScheduler {
  private var now: TimeInterval = 0
  private var timers: [FakeTimer] = []

  func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> TimerHandle {
    let timer = FakeTimer(dueAt: now + delay, work: work)
    timers.append(timer)
    return timer
  }

  func advance(by seconds: TimeInterval) {
    let target = now + seconds
    while let next = timers.filter({ !$0.cancelled && $0.dueAt <= target })
      .min(by: { $0.dueAt < $1.dueAt })
    {
      now = next.dueAt
      next.cancelled = true
      next.work()
    }
    now = target
  }
}

private final class FakeConfigurator: HotspotConfigurator {
  enum Event: Equatable {
    case remove(String)
    case apply(String)
  }

  private(set) var events: [Event] = []
  private var inFlightApplies: [(Error?) -> Void] = []

  func removeConfiguration(forSSID ssid: String) {
    events.append(.remove(ssid))
  }

  func applyJoinOnce(ssid: String, passphrase: String, completion: @escaping (Error?) -> Void) {
    // iOS rejects a second apply while one is in flight (`pending`).
    XCTAssertTrue(inFlightApplies.isEmpty, "apply(\(ssid)) overlaps an in-flight apply")
    events.append(.apply(ssid))
    inFlightApplies.append(completion)
  }

  /// Completes the oldest in-flight `apply`.
  func completeApply(error: Error? = nil) {
    inFlightApplies.removeFirst()(error)
  }

  func clearEvents() { events.removeAll() }
}

private func hotspotError(_ code: NEHotspotConfigurationError) -> NSError {
  NSError(domain: NEHotspotConfigurationErrorDomain, code: code.rawValue)
}

final class HotspotJoinCoordinatorTests: XCTestCase {
  private var configurator: FakeConfigurator!
  private var scheduler: FakeScheduler!
  private var coordinator: HotspotJoinCoordinator!

  override func setUp() {
    super.setUp()
    configurator = FakeConfigurator()
    scheduler = FakeScheduler()
    coordinator = HotspotJoinCoordinator(configurator: configurator, scheduler: scheduler)
  }

  /// Starts a join and returns a getter for the replies it received.
  private func join(
    _ ssid: String = "DEVICE-AP",
    timeout: TimeInterval = 30,
    removeDelay: TimeInterval = 0.3
  ) -> () -> [JoinOutcome] {
    var replies: [JoinOutcome] = []
    coordinator.join(
      ssid: ssid, passphrase: "12345678", timeout: timeout, removeDelay: removeDelay
    ) { replies.append($0) }
    return { replies }
  }

  func testRemovesStaleConfigurationThenAppliesAfterDelay() {
    let replies = join(removeDelay: 0.3)

    XCTAssertEqual(configurator.events, [.remove("DEVICE-AP")])
    scheduler.advance(by: 0.29)
    XCTAssertEqual(configurator.events, [.remove("DEVICE-AP")])
    scheduler.advance(by: 0.01)
    XCTAssertEqual(configurator.events, [.remove("DEVICE-AP"), .apply("DEVICE-AP")])

    configurator.completeApply(error: nil)
    XCTAssertEqual(replies(), [.joined])
  }

  func testAlreadyAssociatedCountsAsJoined() {
    let replies = join()
    scheduler.advance(by: 0.3)

    configurator.completeApply(error: hotspotError(.alreadyAssociated))

    XCTAssertEqual(replies().map(\.status), ["joined"])
    XCTAssertEqual(replies().first?.platformCode, "alreadyAssociated")
  }

  func testApplyErrorMapping() {
    let cases: [(NSError, String, String)] = [
      (hotspotError(.userDenied), "userDenied", "userDenied"),
      (hotspotError(.applicationIsNotInForeground), "notInForeground", "applicationIsNotInForeground"),
      (hotspotError(.invalidWPAPassphrase), "invalidArguments", "invalidWPAPassphrase"),
      (hotspotError(.invalidSSID), "invalidArguments", "invalidSSID"),
      (hotspotError(.pending), "failed", "pending"),
      (hotspotError(.internal), "failed", "internal"),
      (NSError(domain: NEHotspotConfigurationErrorDomain, code: 99), "failed",
       "\(NEHotspotConfigurationErrorDomain)(99)"),
      (NSError(domain: NSPOSIXErrorDomain, code: 1), "failed", "NSPOSIXErrorDomain(1)"),
    ]
    for (error, status, platformCode) in cases {
      let outcome = JoinOutcome(applyError: error)
      XCTAssertEqual(outcome.status, status, "\(error)")
      XCTAssertEqual(outcome.platformCode, platformCode, "\(error)")
    }
  }

  func testTimeoutBeforeApplyNeverApplies() {
    let replies = join(timeout: 0.1, removeDelay: 0.3)

    scheduler.advance(by: 5)

    XCTAssertEqual(replies(), [.timeout])
    XCTAssertFalse(configurator.events.contains(.apply("DEVICE-AP")))
  }

  func testTimeoutRemovesConfigurationAndUndoesLateSuccess() {
    let replies = join(timeout: 1, removeDelay: 0.3)
    scheduler.advance(by: 0.3)
    configurator.clearEvents()

    scheduler.advance(by: 0.7)
    XCTAssertEqual(replies(), [.timeout])
    XCTAssertEqual(configurator.events, [.remove("DEVICE-AP")])

    configurator.completeApply(error: nil)
    XCTAssertEqual(replies(), [.timeout], "replies exactly once")
    XCTAssertEqual(
      configurator.events, [.remove("DEVICE-AP"), .remove("DEVICE-AP")],
      "a configuration installed after the timeout must be removed")
  }

  func testSecondJoinWaitsForInFlightApplyAndUndoesItsLateSuccess() {
    let first = join("DEVICE-AP")
    scheduler.advance(by: 0.3)

    let second = join("DEVICE-AP")
    XCTAssertEqual(first(), [.cancelled])
    scheduler.advance(by: 0.3)
    configurator.clearEvents()
    scheduler.advance(by: 5)
    XCTAssertEqual(configurator.events, [], "the first apply is still in flight")

    // The first apply finishes late: its configuration is removed, then the second join
    // waits the remove delay again before applying.
    configurator.completeApply(error: nil)
    XCTAssertEqual(configurator.events, [.remove("DEVICE-AP")])
    scheduler.advance(by: 0.29)
    XCTAssertEqual(configurator.events, [.remove("DEVICE-AP")])
    scheduler.advance(by: 0.01)
    XCTAssertEqual(configurator.events, [.remove("DEVICE-AP"), .apply("DEVICE-AP")])

    configurator.completeApply(error: nil)
    XCTAssertEqual(second(), [.joined])
    XCTAssertEqual(first(), [.cancelled])
  }

  func testLateSuccessOfCancelledJoinIsRemovedWhenTheReplacementFails() {
    _ = join("DEVICE-AP")
    scheduler.advance(by: 0.3)
    let second = join("DEVICE-AP")
    scheduler.advance(by: 0.3)
    configurator.clearEvents()

    configurator.completeApply(error: nil)
    scheduler.advance(by: 0.3)
    configurator.completeApply(error: hotspotError(.userDenied))

    XCTAssertEqual(second().map(\.status), ["userDenied"])
    XCTAssertEqual(configurator.events, [.remove("DEVICE-AP"), .apply("DEVICE-AP")])
  }

  func testFailedInFlightApplyLetsTheWaitingJoinApplyImmediately() {
    _ = join("OLD-AP")
    scheduler.advance(by: 0.3)
    let second = join("NEW-AP")
    scheduler.advance(by: 0.3)
    configurator.clearEvents()

    configurator.completeApply(error: hotspotError(.userDenied))
    XCTAssertEqual(configurator.events, [.apply("NEW-AP")])

    configurator.completeApply(error: nil)
    XCTAssertEqual(second(), [.joined])
  }

  func testCancelledJoinForAnotherSSIDIsCleanedUp() {
    let first = join("OLD-AP")
    scheduler.advance(by: 0.3)

    _ = join("NEW-AP")
    XCTAssertEqual(first(), [.cancelled])
    XCTAssertTrue(configurator.events.contains(.remove("OLD-AP")))
    configurator.clearEvents()

    configurator.completeApply(error: nil)
    XCTAssertEqual(configurator.events, [.remove("OLD-AP")])
  }

  func testLeaveCancelsPendingJoin() {
    let replies = join()

    coordinator.leave(ssid: "DEVICE-AP")
    scheduler.advance(by: 30)

    XCTAssertEqual(replies(), [.cancelled])
    XCTAssertFalse(configurator.events.contains(.apply("DEVICE-AP")))
  }

  func testLeaveWithoutJoinIsIdempotent() {
    coordinator.leave(ssid: "DEVICE-AP")
    coordinator.leave(ssid: "DEVICE-AP")

    XCTAssertEqual(configurator.events, [.remove("DEVICE-AP"), .remove("DEVICE-AP")])
  }

  func testLeaveRemovesJoinedConfiguration() {
    let replies = join()
    scheduler.advance(by: 0.3)
    configurator.completeApply(error: nil)
    configurator.clearEvents()

    coordinator.leave(ssid: "DEVICE-AP")

    XCTAssertEqual(replies(), [.joined])
    XCTAssertEqual(configurator.events, [.remove("DEVICE-AP")])
  }

  func testDisposeCancelsPendingJoin() {
    let replies = join()

    coordinator.dispose()
    scheduler.advance(by: 30)

    XCTAssertEqual(replies(), [.cancelled])
  }

  func testDisposeRemovesJoinedConfiguration() {
    let replies = join()
    scheduler.advance(by: 0.3)
    configurator.completeApply(error: nil)
    configurator.clearEvents()

    coordinator.dispose()
    coordinator.dispose()

    XCTAssertEqual(replies(), [.joined])
    XCTAssertEqual(configurator.events, [.remove("DEVICE-AP")])
  }

  func testLateSuccessIsUndoneAfterTheCoordinatorIsReleased() {
    let replies = join()
    scheduler.advance(by: 0.3)
    coordinator.dispose()
    weak var released = coordinator
    coordinator = nil
    configurator.clearEvents()

    configurator.completeApply(error: nil)

    XCTAssertEqual(replies(), [.cancelled])
    XCTAssertEqual(configurator.events, [.remove("DEVICE-AP")])
    XCTAssertNil(released, "nothing retains the coordinator once the apply completed")
  }
}
