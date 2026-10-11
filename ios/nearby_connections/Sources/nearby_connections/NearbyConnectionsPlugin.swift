import Flutter
import NearbyConnections
import UIKit

/// Incoming requests are accepted at the advertiser stage; the verification
/// step is held until Dart calls `acceptConnection` or `rejectConnection`.
public class NearbyConnectionsPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  fileprivate static let defaultServiceId = "com.pkmnapps.nearby_connections"

  /// No Wi-Fi hotspot: joining one takes the iPhone off its current network.
  private static let mediums: Set<Medium> = [.ble, .bluetooth, .wifiLAN, .awdl]

  private var eventSink: FlutterEventSink?
  private var connectionManager: ConnectionManager?
  private var managerConfig: ManagerConfig?
  // Kept after stopping so connections they started keep reporting events.
  private var advertiser: Advertiser?
  private var discoverer: Discoverer?

  private var endpointNames: [EndpointID: String] = [:]
  private var outgoingEndpoints: Set<EndpointID> = []
  private var connectedEndpoints: Set<EndpointID> = []
  private var verificationHandlers: [EndpointID: (Bool) -> Void] = [:]
  private var transferProgress: [PayloadID: (completed: Int64, total: Int64)] = [:]
  private var cancellationTokens: [PayloadID: CancellationToken] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NearbyConnectionsPlugin()
    let channel = FlutterMethodChannel(
      name: "nearby_connections", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    let eventChannel = FlutterEventChannel(
      name: "nearby_connections/events", binaryMessenger: registrar.messenger())
    eventChannel.setStreamHandler(instance)
  }

  public func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "startAdvertising": startAdvertising(args, result: result)
    case "stopAdvertising": stopAdvertising(result: result)
    case "startDiscovery": startDiscovery(args, result: result)
    case "stopDiscovery": stopDiscovery(result: result)
    case "requestConnection": requestConnection(args, result: result)
    case "acceptConnection": answerConnection(args, accept: true, result: result)
    case "rejectConnection": answerConnection(args, accept: false, result: result)
    case "disconnectFromEndpoint": disconnectFromEndpoint(args, result: result)
    case "stopAllEndpoints": stopAllEndpoints(result: result)
    case "sendPayload": sendPayload(args, result: result)
    case "sendFilePayload": sendFilePayload(args, result: result)
    case "cancelPayload": cancelPayload(args, result: result)
    case "copyFileAndDeleteOriginal": copyFileAndDeleteOriginal(args, result: result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func startAdvertising(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let name = args["userNickName"] as? String else {
      return result(Self.missingArgument("userNickName"))
    }
    guard let manager = manager(for: args, result: result) else { return }
    let advertiser = self.advertiser ?? makeAdvertiser(manager)
    advertiser.startAdvertising(using: Data(name.utf8), mediums: Self.mediums) { error in
      Self.complete(result, error: error, value: true)
    }
  }

  private func stopAdvertising(result: @escaping FlutterResult) {
    guard let advertiser = advertiser else { return result(nil) }
    advertiser.stopAdvertising { _ in Self.complete(result, error: nil, value: nil) }
  }

  private func startDiscovery(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let manager = manager(for: args, result: result) else { return }
    let discoverer = self.discoverer ?? makeDiscoverer(manager)
    discoverer.startDiscovery(mediums: Self.mediums) { error in
      Self.complete(result, error: error, value: true)
    }
  }

  private func stopDiscovery(result: @escaping FlutterResult) {
    guard let discoverer = discoverer else { return result(nil) }
    discoverer.stopDiscovery { _ in Self.complete(result, error: nil, value: nil) }
  }

  private func manager(for args: [String: Any], result: FlutterResult) -> ConnectionManager? {
    let config = ManagerConfig(args)
    if let manager = connectionManager, managerConfig == config { return manager }
    if !connectedEndpoints.isEmpty || !verificationHandlers.isEmpty {
      result(
        FlutterError(
          code: "Failure",
          message: "Nearby is in use for service \(managerConfig?.serviceId ?? "")",
          details: nil))
      return nil
    }
    advertiser?.stopAdvertising()
    discoverer?.stopDiscovery()
    advertiser = nil
    discoverer = nil
    let manager = ConnectionManager(serviceID: config.serviceId, strategy: config.strategy)
    manager.delegate = self
    connectionManager = manager
    managerConfig = config
    return manager
  }

  private func makeAdvertiser(_ manager: ConnectionManager) -> Advertiser {
    let advertiser = Advertiser(connectionManager: manager)
    advertiser.delegate = self
    self.advertiser = advertiser
    return advertiser
  }

  private func makeDiscoverer(_ manager: ConnectionManager) -> Discoverer {
    let discoverer = Discoverer(connectionManager: manager)
    discoverer.delegate = self
    self.discoverer = discoverer
    return discoverer
  }

  private func requestConnection(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let name = args["userNickName"] as? String else {
      return result(Self.missingArgument("userNickName"))
    }
    guard let endpointId = args["endpointId"] as? String else {
      return result(Self.missingArgument("endpointId"))
    }
    guard let manager = connectionManager else {
      return result(Self.notStarted("requestConnection"))
    }
    let discoverer = self.discoverer ?? makeDiscoverer(manager)
    // Kept on failure so later state changes still reach the `dis.` callbacks.
    outgoingEndpoints.insert(endpointId)
    discoverer.requestConnection(
      to: endpointId, using: Data(name.utf8), mediums: Self.mediums
    ) { error in
      Self.complete(result, error: error, value: true)
    }
  }

  private func answerConnection(
    _ args: [String: Any], accept: Bool, result: @escaping FlutterResult
  ) {
    guard let endpointId = args["endpointId"] as? String else {
      return result(Self.missingArgument("endpointId"))
    }
    guard let handler = verificationHandlers.removeValue(forKey: endpointId) else {
      return result(
        FlutterError(
          code: "Failure", message: "No pending connection for \(endpointId)", details: nil))
    }
    handler(accept)
    result(true)
  }

  private func disconnectFromEndpoint(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let endpointId = args["endpointId"] as? String else {
      return result(Self.missingArgument("endpointId"))
    }
    connectionManager?.disconnect(from: endpointId)
    result(nil)
  }

  private func stopAllEndpoints(result: @escaping FlutterResult) {
    // Cancelled unanswered requests get no further event, so forget them here.
    let unanswered = outgoingEndpoints
      .subtracting(connectedEndpoints)
      .subtracting(verificationHandlers.keys)
    let pending = verificationHandlers
    verificationHandlers.removeAll()
    pending.values.forEach { $0(false) }
    connectedEndpoints.union(unanswered).forEach { connectionManager?.disconnect(from: $0) }
    outgoingEndpoints.subtract(unanswered)
    result(nil)
  }

  private func sendPayload(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let endpointId = args["endpointId"] as? String else {
      return result(Self.missingArgument("endpointId"))
    }
    guard let bytes = args["bytes"] as? FlutterStandardTypedData else {
      return result(Self.missingArgument("bytes"))
    }
    guard let manager = connectionManager else {
      return result(Self.notStarted("sendPayload"))
    }
    _ = manager.send(bytes.data, to: [endpointId]) { error in
      Self.complete(result, error: error, value: true)
    }
  }

  private func sendFilePayload(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let endpointId = args["endpointId"] as? String else {
      return result(Self.missingArgument("endpointId"))
    }
    guard let filePath = args["filePath"] as? String else {
      return result(Self.missingArgument("filePath"))
    }
    guard let manager = connectionManager else {
      return result(Self.notStarted("sendFilePayload"))
    }
    guard FileManager.default.fileExists(atPath: filePath) else {
      return result(
        FlutterError(code: "Failure", message: "File not found: \(filePath)", details: nil))
    }
    let fileURL = URL(fileURLWithPath: filePath)
    let payloadId = PayloadID.random(in: 1...PayloadID.max)
    cancellationTokens[payloadId] = manager.sendResource(
      at: fileURL, withName: fileURL.lastPathComponent, to: [endpointId], id: payloadId
    ) { error in
      Self.complete(result, error: error, value: payloadId)
    }
  }

  private func cancelPayload(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let payloadId = (args["payloadId"] as? String).flatMap({ PayloadID($0) }) else {
      return result(Self.missingArgument("payloadId"))
    }
    cancellationTokens.removeValue(forKey: payloadId)?.cancel()
    result(nil)
  }

  private func copyFileAndDeleteOriginal(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let source = (args["sourceUri"] as? String).flatMap({ URL(string: $0) }),
      let destinationPath = args["destinationFilepath"] as? String
    else {
      return result(Self.missingArgument("sourceUri or destinationFilepath"))
    }
    let destination = URL(fileURLWithPath: destinationPath)
    do {
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: source, to: destination)
      try FileManager.default.removeItem(at: source)
      result(true)
    } catch {
      NSLog("nearby_connections: copyFileAndDeleteOriginal failed: %@", "\(error)")
      result(false)
    }
  }

  private func emit(_ method: String, _ args: [String: Any]) {
    var event = args
    event["method"] = method
    eventSink?(event)
  }

  private func prefix(for endpointId: EndpointID) -> String {
    outgoingEndpoints.contains(endpointId) ? "dis" : "ad"
  }

  private func forget(_ endpointId: EndpointID) {
    outgoingEndpoints.remove(endpointId)
    connectedEndpoints.remove(endpointId)
    verificationHandlers.removeValue(forKey: endpointId)
  }

  private static func decodeName(_ context: Data) -> String {
    String(decoding: context, as: UTF8.self)
  }

  /// Nearby calls completion handlers off the main thread.
  private static func complete(_ result: @escaping FlutterResult, error: Error?, value: Any?) {
    DispatchQueue.main.async {
      guard let error = error else { return result(value) }
      result(flutterError(error))
    }
  }

  /// Uses Android status codes (e.g. 8001) where one exists.
  private static func flutterError(_ error: Error) -> FlutterError {
    let nsError = error as NSError
    var code = nsError.code
    if nsError.domain == nearbyErrorDomain, let androidCode = androidStatusCodes[nsError.code] {
      code = androidCode
    }
    return FlutterError(
      code: String(code),
      message: "\(code): \(nsError.localizedDescription)",
      details: "\(nsError.domain) \(nsError.code)")
  }

  private static let nearbyErrorDomain = "com.google.nearby.connections.error"

  /// `GNCErrorCode` values mapped to Android `ConnectionsStatusCodes`.
  private static let androidStatusCodes: [Int: Int] = [
    3: 8001,  // alreadyAdvertising
    4: 8002,  // alreadyDiscovering
    8: 8004,  // connectionRejected
    9: 8003,  // alreadyConnectedToEndpoint
    10: 8005,  // notConnectedToEndpoint
  ]

  private static func missingArgument(_ name: String) -> FlutterError {
    FlutterError(code: "Failure", message: "Missing argument: \(name)", details: nil)
  }

  private static func notStarted(_ method: String) -> FlutterError {
    FlutterError(
      code: "Failure",
      message: "\(method) requires startAdvertising or startDiscovery first",
      details: nil)
  }
}

extension NearbyConnectionsPlugin: AdvertiserDelegate {
  public func advertiser(
    _ advertiser: Advertiser, didReceiveConnectionRequestFrom endpointID: EndpointID,
    with context: Data, connectionRequestHandler: @escaping (Bool) -> Void
  ) {
    endpointNames[endpointID] = Self.decodeName(context)
    connectionRequestHandler(true)
  }
}

extension NearbyConnectionsPlugin: DiscovererDelegate {
  public func discoverer(
    _ discoverer: Discoverer, didFind endpointID: EndpointID, with context: Data
  ) {
    let name = Self.decodeName(context)
    endpointNames[endpointID] = name
    emit(
      "dis.onEndpointFound",
      [
        "endpointId": endpointID,
        "endpointName": name,
        "serviceId": discoverer.connectionManager.serviceID,
      ])
  }

  public func discoverer(_ discoverer: Discoverer, didLose endpointID: EndpointID) {
    emit("dis.onEndpointLost", ["endpointId": endpointID])
  }
}

extension NearbyConnectionsPlugin: ConnectionManagerDelegate {
  public func connectionManager(
    _ connectionManager: ConnectionManager, didReceive verificationCode: String,
    from endpointID: EndpointID, verificationHandler: @escaping (Bool) -> Void
  ) {
    verificationHandlers[endpointID] = verificationHandler
    emit(
      "\(prefix(for: endpointID)).onConnectionInitiated",
      [
        "endpointId": endpointID,
        "endpointName": endpointNames[endpointID] ?? "",
        "authenticationToken": verificationCode,
        "isIncomingConnection": !outgoingEndpoints.contains(endpointID),
      ])
  }

  public func connectionManager(
    _ connectionManager: ConnectionManager, didReceive data: Data, withID payloadID: PayloadID,
    from endpointID: EndpointID
  ) {
    emit(
      "onPayloadReceived",
      [
        "endpointId": endpointID,
        "payloadId": payloadID,
        "type": PayloadTypeIndex.bytes,
        "bytes": FlutterStandardTypedData(bytes: data),
      ])
  }

  public func connectionManager(
    _ connectionManager: ConnectionManager, didReceive stream: InputStream,
    withID payloadID: PayloadID, from endpointID: EndpointID,
    cancellationToken token: CancellationToken
  ) {
    cancellationTokens[payloadID] = token
    emit(
      "onPayloadReceived",
      ["endpointId": endpointID, "payloadId": payloadID, "type": PayloadTypeIndex.stream])
  }

  public func connectionManager(
    _ connectionManager: ConnectionManager, didStartReceivingResourceWithID payloadID: PayloadID,
    from endpointID: EndpointID, at localURL: URL, withName name: String,
    cancellationToken token: CancellationToken
  ) {
    cancellationTokens[payloadID] = token
    emit(
      "onPayloadReceived",
      [
        "endpointId": endpointID,
        "payloadId": payloadID,
        "type": PayloadTypeIndex.file,
        "uri": localURL.absoluteString,
        "filePath": localURL.path,
      ])
  }

  public func connectionManager(
    _ connectionManager: ConnectionManager, didReceiveTransferUpdate update: TransferUpdate,
    from endpointID: EndpointID, forPayload payloadID: PayloadID
  ) {
    let status: Int
    switch update {
    case .progress(let progress):
      status = PayloadStatusIndex.inProgress
      transferProgress[payloadID] = (progress.completedUnitCount, progress.totalUnitCount)
    case .success: status = PayloadStatusIndex.success
    case .failure: status = PayloadStatusIndex.failure
    case .canceled: status = PayloadStatusIndex.canceled
    }
    let counts = transferProgress[payloadID] ?? (0, 0)
    if status != PayloadStatusIndex.inProgress {
      transferProgress.removeValue(forKey: payloadID)
      cancellationTokens.removeValue(forKey: payloadID)
    }
    emit(
      "onPayloadTransferUpdate",
      [
        "endpointId": endpointID,
        "payloadId": payloadID,
        "status": status,
        "bytesTransferred": counts.completed,
        "totalBytes": counts.total,
      ])
  }

  public func connectionManager(
    _ connectionManager: ConnectionManager, didChangeTo state: ConnectionState,
    for endpointID: EndpointID
  ) {
    let prefix = prefix(for: endpointID)
    switch state {
    case .connecting:
      return
    case .connected:
      connectedEndpoints.insert(endpointID)
      emit("\(prefix).onConnectionResult", ["endpointId": endpointID, "statusCode": 0])
    case .rejected:
      forget(endpointID)
      emit("\(prefix).onConnectionResult", ["endpointId": endpointID, "statusCode": 1])
    case .disconnected:
      let wasConnected = connectedEndpoints.contains(endpointID)
      forget(endpointID)
      if wasConnected {
        emit("\(prefix).onDisconnected", ["endpointId": endpointID])
      } else {
        emit("\(prefix).onConnectionResult", ["endpointId": endpointID, "statusCode": 2])
      }
    }
  }
}

private struct ManagerConfig: Equatable {
  let serviceId: String
  let strategy: Strategy

  init(_ args: [String: Any]) {
    let serviceId = args["serviceId"] as? String ?? ""
    self.serviceId = serviceId.isEmpty ? NearbyConnectionsPlugin.defaultServiceId : serviceId
    // Indices of the Dart `Strategy` enum.
    switch args["strategy"] as? Int {
    case 1: strategy = .star
    case 2: strategy = .pointToPoint
    default: strategy = .cluster
    }
  }
}

/// Indices of the Dart `PayloadType` enum.
private enum PayloadTypeIndex {
  static let bytes = 1
  static let file = 2
  static let stream = 3
}

/// Indices of the Dart `PayloadStatus` enum.
private enum PayloadStatusIndex {
  static let success = 1
  static let failure = 2
  static let inProgress = 3
  static let canceled = 4
}
