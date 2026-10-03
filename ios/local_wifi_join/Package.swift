// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "local_wifi_join",
  platforms: [
    .iOS("13.0")
  ],
  products: [
    .library(name: "local-wifi-join", targets: ["local_wifi_join"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework")
  ],
  targets: [
    .target(
      name: "local_wifi_join",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework")
      ],
      resources: [
        .process("PrivacyInfo.xcprivacy")
      ],
      linkerSettings: [
        .linkedFramework("Network"),
        .linkedFramework("NetworkExtension"),
      ]
    )
  ]
)
