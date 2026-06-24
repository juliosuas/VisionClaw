import Foundation

class OpenClawEventClient {
  var onNotification: ((String) -> Void)?
  var onPairingStatusChange: ((PairingStatus) -> Void)?

  private enum HandshakeAuthMode: String {
    case bootstrap
    case device
    case gatewayFallback = "gateway_fallback"
  }

  enum PairingStatus {
    case disconnected
    case connecting
    case waitingApproval
    case paired
    case error(String)
  }

  private var webSocketTask: URLSessionWebSocketTask?
  private var session: URLSession?
  private var isConnected = false
  private var shouldReconnect = false
  private var reconnectDelay: TimeInterval = 2
  private let maxReconnectDelay: TimeInterval = 30
  private let settings = SettingsManager.shared

  func connect() {
    guard GeminiConfig.isOpenClawConfigured else {
      NSLog("[OpenClawWS] Not configured, skipping")
      return
    }

    shouldReconnect = true
    reconnectDelay = 2
    onPairingStatusChange?(.connecting)

    // If we have a setup code and are not yet paired, use it for bootstrap
    let setupCode = settings.openClawSetupCode
    if !settings.isPaired && !setupCode.isEmpty, let decoded = parseSetupCode(setupCode) {
      NSLog("[OpenClawWS] Using setup code for bootstrap pairing")
      pendingBootstrapToken = decoded.bootstrapToken
      establishConnection(overrideURL: decoded.url, bootstrapToken: decoded.bootstrapToken)
    } else {
      establishConnection()
    }
  }

  func disconnect() {
    shouldReconnect = false
    isConnected = false
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    session?.invalidateAndCancel()
    session = nil
    onPairingStatusChange?(.disconnected)
    NSLog("[OpenClawWS] Disconnected")
  }

  /// Parse a setup code (base64 JSON) and initiate pairing
  func startPairing(setupCode: String) {
    guard let decoded = parseSetupCode(setupCode) else {
      NSLog("[OpenClawWS] Invalid setup code")
      onPairingStatusChange?(.error("Invalid setup code"))
      return
    }

    // Store the bootstrap token temporarily
    settings.openClawSetupCode = setupCode

    // Connect using the URL from the setup code
    shouldReconnect = true
    reconnectDelay = 2
    onPairingStatusChange?(.connecting)
    establishConnection(overrideURL: decoded.url, bootstrapToken: decoded.bootstrapToken)
  }

  // MARK: - Private

  private struct SetupCodePayload {
    let url: String
    let bootstrapToken: String
  }

  private func parseSetupCode(_ code: String) -> SetupCodePayload? {
    // Clean up whitespace/newlines
    let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: cleaned),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let url = json["url"] as? String,
          let token = json["bootstrapToken"] as? String else {
      return nil
    }
    return SetupCodePayload(url: url, bootstrapToken: token)
  }

  private func establishConnection(overrideURL: String? = nil, bootstrapToken: String? = nil) {
    let urlString: String

    if let override = overrideURL {
      urlString = override
    } else {
      let hostSetting = GeminiConfig.openClawHost.trimmingCharacters(in: .whitespacesAndNewlines)
      let usesTLS = hostSetting.lowercased().hasPrefix("https://")
      let socketScheme = usesTLS ? "wss" : "ws"
      let host = hostSetting
        .replacingOccurrences(of: "http://", with: "")
        .replacingOccurrences(of: "https://", with: "")
      let port = GeminiConfig.openClawPort
      urlString = "\(socketScheme)://\(host):\(port)"
    }

    guard let url = URL(string: urlString) else {
      NSLog("[OpenClawWS] Invalid URL: %@", urlString)
      onPairingStatusChange?(.error("Invalid URL"))
      return
    }

    // Store bootstrap token for handshake
    if let token = bootstrapToken {
      pendingBootstrapToken = token
    }

    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    session = URLSession(configuration: config)

    // The gateway validates the auth token at the HTTP WebSocket upgrade level.
    // Pass it as an Authorization: Bearer header so the upgrade is authenticated
    // before any WebSocket message is exchanged. Without this, the gateway closes
    // the socket immediately with "token_missing" before ever receiving the
    // connect handshake message.
    var request = URLRequest(url: url)
    let gatewayToken = GeminiConfig.openClawGatewayToken
    if !gatewayToken.isEmpty {
      request.setValue("Bearer \(gatewayToken)", forHTTPHeaderField: "Authorization")
    }
    webSocketTask = session?.webSocketTask(with: request)
    webSocketTask?.resume()

    NSLog("[OpenClawWS] Connecting to %@", url.absoluteString)
    startReceiving()
  }

  private var pendingBootstrapToken: String?

  private func startReceiving() {
    webSocketTask?.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let message):
        switch message {
        case .string(let text):
          self.handleMessage(text)
        case .data(let data):
          if let text = String(data: data, encoding: .utf8) {
            self.handleMessage(text)
          }
        @unknown default:
          break
        }
        self.startReceiving()
      case .failure(let error):
        NSLog("[OpenClawWS] Receive error: %@", error.localizedDescription)
        self.isConnected = false
        self.onPairingStatusChange?(.disconnected)
        self.scheduleReconnect()
      }
    }
  }

  private func handleMessage(_ text: String) {
    guard let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String else { return }

    if type == "event" {
      handleEvent(json)
    } else if type == "res" {
      handleResponse(json)
    }
  }

  private func handleResponse(_ json: [String: Any]) {
    let ok = json["ok"] as? Bool ?? false

    if ok {
      // Check if we got a device token back (pairing approved)
      if let result = json["result"] as? [String: Any],
         let deviceToken = result["token"] as? String, !deviceToken.isEmpty {
        // Pairing complete — save the device token
        settings.openClawDeviceToken = deviceToken
        settings.openClawSetupCode = "" // Clear bootstrap code
        pendingBootstrapToken = nil
        NSLog("[OpenClawWS] Pairing complete! Device token saved.")
        onPairingStatusChange?(.paired)
      }

      NSLog("[OpenClawWS] Connected and authenticated")
      isConnected = true
      reconnectDelay = 2
      if settings.isPaired {
        onPairingStatusChange?(.paired)
      }
    } else {
      let error = json["error"] as? [String: Any]
      let msg = error?["message"] as? String ?? "unknown"
      let code = error?["code"] as? String ?? ""

      NSLog("[OpenClawWS] Connect failed: %@ (code: %@)", msg, code)

      if msg.contains("pairing") || msg.contains("approval") || code == "pairing_pending" {
        onPairingStatusChange?(.waitingApproval)
        NSLog("[OpenClawWS] Device pairing pending — waiting for approval on gateway")
      } else {
        onPairingStatusChange?(.error(msg))
      }
    }
  }

  private func handleEvent(_ json: [String: Any]) {
    guard let event = json["event"] as? String else { return }
    let payload = json["payload"] as? [String: Any] ?? [:]

    switch event {
    case "connect.challenge":
      sendConnectHandshake()

    case "heartbeat":
      handleHeartbeatEvent(payload)

    case "cron":
      handleCronEvent(payload)

    case "device.paired":
      // Gateway confirmed pairing
      if let token = payload["token"] as? String, !token.isEmpty {
        settings.openClawDeviceToken = token
        settings.openClawSetupCode = ""
        pendingBootstrapToken = nil
        NSLog("[OpenClawWS] Device paired via event! Token saved.")
        onPairingStatusChange?(.paired)
      }

    default:
      break
    }
  }

  private func sendConnectHandshake() {
    let deviceId = settings.openClawDeviceId
    let (authToken, authMode) = handshakeToken()
    let auth: [String: Any] = ["token": authToken]

    let connectMsg: [String: Any] = [
      "type": "req",
      "id": UUID().uuidString,
      "method": "connect",
      "params": [
        "minProtocol": 3,
        "maxProtocol": 3,
        "client": [
          "id": "cli",
          "displayName": "VisionClaw Glasses",
          "version": "2.0",
          "platform": "ios",
          "mode": "node"
        ],
        "role": "node",
        "scopes": [] as [String],
        "caps": ["camera", "voice"],
        "commands": [] as [String],
        "permissions": [:] as [String: Any],
        "auth": auth
      ] as [String: Any]
    ]

    guard let data = try? JSONSerialization.data(withJSONObject: connectMsg),
          let string = String(data: data, encoding: .utf8) else { return }

    NSLog("[OpenClawWS] Sending handshake (mode: %@, paired: %@, deviceId: %@)",
          authMode.rawValue, settings.isPaired ? "yes" : "no", String(deviceId.prefix(8)))

    webSocketTask?.send(.string(string)) { error in
      if let error {
        NSLog("[OpenClawWS] Handshake send error: %@", error.localizedDescription)
      }
    }
  }

  private func handleHeartbeatEvent(_ payload: [String: Any]) {
    let status = payload["status"] as? String ?? ""
    guard status == "sent", let preview = payload["preview"] as? String, !preview.isEmpty else {
      return
    }

    let silent = payload["silent"] as? Bool ?? false
    guard !silent else { return }

    NSLog("[OpenClawWS] Heartbeat notification: %@", String(preview.prefix(100)))
    onNotification?("[Notification from your assistant] \(preview)")
  }

  private func handleCronEvent(_ payload: [String: Any]) {
    let action = payload["action"] as? String ?? ""
    guard action == "finished" else { return }

    let summary = payload["summary"] as? String
      ?? payload["result"] as? String
      ?? ""
    guard !summary.isEmpty else { return }

    NSLog("[OpenClawWS] Cron notification: %@", String(summary.prefix(100)))
    onNotification?("[Scheduled update] \(summary)")
  }

  private func scheduleReconnect() {
    guard shouldReconnect else { return }
    NSLog("[OpenClawWS] Reconnecting in %.0fs", reconnectDelay)
    DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
      guard let self, self.shouldReconnect else { return }
      self.reconnectDelay = min(self.reconnectDelay * 2, self.maxReconnectDelay)
      self.establishConnection()
    }
  }

  private func handshakeToken() -> (String, HandshakeAuthMode) {
    if let pendingBootstrapToken, !pendingBootstrapToken.isEmpty {
      return (pendingBootstrapToken, .bootstrap)
    }

    let deviceToken = settings.openClawDeviceToken
    if !deviceToken.isEmpty {
      return (deviceToken, .device)
    }

    return (GeminiConfig.openClawGatewayToken, .gatewayFallback)
  }
}
