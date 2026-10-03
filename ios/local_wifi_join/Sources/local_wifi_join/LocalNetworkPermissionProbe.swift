import Foundation
import Network
import dnssd

enum LocalNetworkPermissionStatus: String {
  case granted
  case denied
  case timedOut
  case failed
}

/// One-shot probe that triggers the iOS Local Network permission prompt and reports the outcome.
///
/// Publishes a Bonjour service under a random name and browses for the same type: seeing any
/// result proves access, a `kDNSServiceErr_PolicyDenied` error from either the listener or the
/// browser proves denial. Other `waiting` errors are transient (for example no network yet) and
/// leave the probe running until it times out. Each probe owns its listener, browser and queue,
/// so concurrent probes don't interfere.
final class LocalNetworkPermissionProbe {
  private let serviceType: String
  private let timeout: TimeInterval
  private let queue = DispatchQueue(label: "io.github.terryhuanghd.local_wifi_join.permission-probe")
  // Accessed on `queue` only.
  private var listener: NWListener?
  private var browser: NWBrowser?
  private var timeoutItem: DispatchWorkItem?
  private var completion: ((LocalNetworkPermissionStatus) -> Void)?

  init(serviceType: String, timeout: TimeInterval) {
    self.serviceType = serviceType
    self.timeout = timeout
  }

  /// Starts the probe. `completion` runs exactly once, on the main queue.
  func start(completion: @escaping (LocalNetworkPermissionStatus) -> Void) {
    queue.async { [self] in
      self.completion = completion
      do {
        let listener = try NWListener(using: .tcp)
        listener.service = NWListener.Service(name: UUID().uuidString, type: serviceType)
        listener.stateUpdateHandler = { [weak self] state in
          switch state {
          case .failed(let error): self?.failed(error)
          case .waiting(let error): self?.waiting(error)
          default: break
          }
        }
        listener.newConnectionHandler = { connection in
          connection.cancel()
        }

        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
          switch state {
          case .failed(let error): self?.failed(error)
          case .waiting(let error): self?.waiting(error)
          default: break
          }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
          if !results.isEmpty {
            self?.finish(.granted)
          }
        }

        let timeoutItem = DispatchWorkItem { [weak self] in self?.finish(.timedOut) }
        self.listener = listener
        self.browser = browser
        self.timeoutItem = timeoutItem
        listener.start(queue: queue)
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
      } catch {
        finish(.failed)
      }
    }
  }

  /// Stops the probe early; the completion reports `failed`.
  func cancel() {
    queue.async { [self] in finish(.failed) }
  }

  /// Must run on `queue`. A listener or browser stopped with `error`.
  private func failed(_ error: NWError) {
    finish(Self.isPolicyDenied(error) ? .denied : .failed)
  }

  /// Must run on `queue`. A listener or browser is waiting because of `error`.
  private func waiting(_ error: NWError) {
    if Self.isPolicyDenied(error) {
      finish(.denied)
    }
  }

  /// Must run on `queue`.
  private func finish(_ status: LocalNetworkPermissionStatus) {
    guard let completion else { return }
    self.completion = nil
    timeoutItem?.cancel()
    browser?.cancel()
    listener?.cancel()
    timeoutItem = nil
    browser = nil
    listener = nil
    DispatchQueue.main.async { completion(status) }
  }

  private static func isPolicyDenied(_ error: NWError) -> Bool {
    if case .dns(let code) = error {
      return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
    }
    return false
  }
}
