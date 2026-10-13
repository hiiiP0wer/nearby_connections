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
    // google/nearby publishes no SwiftPM version tags, so pin a commit on main.
    .package(
      url: "https://github.com/google/nearby",
      revision: "2e9ff95062bd003555e4c11d9096adb859cfce72"
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
