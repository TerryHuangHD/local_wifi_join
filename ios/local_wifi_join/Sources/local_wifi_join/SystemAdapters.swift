import Foundation
import NetworkExtension

/// `HotspotConfigurator` backed by `NEHotspotConfigurationManager.shared`.
///
/// Requires the `com.apple.developer.networking.HotspotConfiguration` entitlement.
final class SystemHotspotConfigurator: HotspotConfigurator {
  func removeConfiguration(forSSID ssid: String) {
    NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
  }

  func applyJoinOnce(ssid: String, passphrase: String, completion: @escaping (Error?) -> Void) {
    let configuration = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
    configuration.joinOnce = true
    NEHotspotConfigurationManager.shared.apply(configuration) { error in
      DispatchQueue.main.async { completion(error) }
    }
  }
}

extension DispatchWorkItem: TimerHandle {}

/// `MainScheduler` backed by `DispatchQueue.main`.
final class MainQueueScheduler: MainScheduler {
  func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> TimerHandle {
    let item = DispatchWorkItem(block: work)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    return item
  }
}
