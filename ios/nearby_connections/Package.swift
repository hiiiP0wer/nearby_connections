// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "nearby_connections",
  platforms: [
    .iOS("13.0")
  ],
  products: [
    .library(name: "nearby-connections", targets: ["nearby_connections"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
    // Fork of google/nearby at 2e9ff950 plus a fix for iOS centrals truncating BLE packets from
    // Android peripherals (fix/ios-weave-packet-size). Repoint upstream once it lands there.
    .package(
      url: "https://github.com/hiiiP0wer/nearby",
      revision: "5b43d83c21445edabc5fe97160783a4121d418d9"
    ),
  ],
  targets: [
    .target(
      name: "nearby_connections",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework"),
        .product(name: "NearbyConnections", package: "nearby"),
      ]
    )
  ]
)
