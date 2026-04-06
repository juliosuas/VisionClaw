import Foundation

enum OpenClawConnectionState: Equatable {
  case notConfigured
  case checking
  case connected
  case unreachable(String)
}

@MainActor
class OpenClawBridge: ObservableObject {
  @Published var lastToolCallStatus: ToolCallStatus = .idle
  @Published var connectionState: OpenClawConnectionState = .notConfigured

  private let session: URLSession
  private let pingSession: URLSession
  private var sessionKey: String
  private var conversationHistory: [[String: String]] = []
  private let maxHistoryTurns = 10

  private static let stableSessionKey = "agent:main:glass"

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 120
    self.session = URLSession(configuration: config)

    let pingConfig = URLSessionConfiguration.default
    pingConfig.timeoutIntervalForRequest = 5
    self.pingSession = URLSession(configuration: pingConfig)

    self.sessionKey = OpenClawBridge.stableSessionKey
  }

  func checkConnection() async {
    guard GeminiConfig.isOpenClawConfigured else {
      connectionState = .notConfigured
      return
    }
    connectionState = .checking

    // Step 1: Check gateway health endpoint
    guard let healthURL = URL(string: "\(GeminiConfig.openClawHost):\(GeminiConfig.openClawPort)/health") else {
      connectionState = .unreachable("Invalid URL")
      return
    }
    var healthRequest = URLRequest(url: healthURL)
    healthRequest.httpMethod = "GET"
    do {
      let (_, healthResponse) = try await pingSession.data(for: healthRequest)
      if let http = healthResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        connectionState = .unreachable("Gateway not running (HTTP \(http.statusCode))")
        NSLog("[OpenClaw] Gateway health check failed: HTTP %d", http.statusCode)
        return
      }
    } catch {
      connectionState = .unreachable("Gateway unreachable: \(error.localizedDescription)")
      NSLog("[OpenClaw] Gateway unreachable: %@", error.localizedDescription)
      return
    }

    // Step 2: Verify chat completions endpoint is enabled
    guard let chatURL = URL(string: "\(GeminiConfig.openClawHost):\(GeminiConfig.openClawPort)/v1/chat/completions") else {
      connectionState = .unreachable("Invalid URL")
      return
    }
    var chatRequest = URLRequest(url: chatURL)
    chatRequest.httpMethod = "GET"
    chatRequest.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    chatRequest.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")
    do {
      let (_, chatResponse) = try await pingSession.data(for: chatRequest)
      if let http = chatResponse as? HTTPURLResponse {
        switch http.statusCode {
        case 200...299, 405:
          // 405 Method Not Allowed on GET is expected — endpoint exists and is enabled
          connectionState = .connected
          NSLog("[OpenClaw] Gateway connected (HTTP %d)", http.statusCode)
        case 401, 403:
          connectionState = .unreachable("Authentication failed (HTTP \(http.statusCode)) — check your gateway token")
          NSLog("[OpenClaw] Auth failed: HTTP %d", http.statusCode)
        case 404:
          connectionState = .unreachable("chatCompletions endpoint disabled — enable it in openclaw.json")
          NSLog("[OpenClaw] Endpoint disabled: HTTP 404. Set gateway.http.endpoints.chatCompletions.enabled = true in ~/.openclaw/openclaw.json")
        default:
          connectionState = .unreachable("Unexpected response (HTTP \(http.statusCode))")
          NSLog("[OpenClaw] Unexpected status: HTTP %d", http.statusCode)
        }
      }
    } catch {
      connectionState = .unreachable(error.localizedDescription)
      NSLog("[OpenClaw] Chat endpoint check failed: %@", error.localizedDescription)
    }
  }

  func resetSession() {
    conversationHistory = []
    NSLog("[OpenClaw] Session reset (key retained: %@)", sessionKey)
  }

  // MARK: - Agent Chat (session continuity via x-openclaw-session-key header)

  func delegateTask(
    task: String,
    toolName: String = "execute"
  ) async -> ToolResult {
    lastToolCallStatus = .executing(toolName)

    guard let url = URL(string: "\(GeminiConfig.openClawHost):\(GeminiConfig.openClawPort)/v1/chat/completions") else {
      lastToolCallStatus = .failed(toolName, "Invalid URL")
      return .failure("Invalid gateway URL")
    }

    // Append the new user message to conversation history
    conversationHistory.append(["role": "user", "content": task])

    // Trim history to keep only the most recent turns (user+assistant pairs)
    if conversationHistory.count > maxHistoryTurns * 2 {
      conversationHistory = Array(conversationHistory.suffix(maxHistoryTurns * 2))
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")
    request.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")
    request.setValue("operator.write", forHTTPHeaderField: "x-openclaw-scopes")

    let body: [String: Any] = [
      "model": "openclaw",
      "messages": conversationHistory,
      "stream": false
    ]

    NSLog("[OpenClaw] Sending %d messages in conversation", conversationHistory.count)

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await session.data(for: request)
      let httpResponse = response as? HTTPURLResponse

      guard let statusCode = httpResponse?.statusCode, (200...299).contains(statusCode) else {
        let code = httpResponse?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
        NSLog("[OpenClaw] Chat failed: HTTP %d - %@", code, String(bodyStr.prefix(200)))
        lastToolCallStatus = .failed(toolName, "HTTP \(code)")
        return .failure("Agent returned HTTP \(code)")
      }

      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let choices = json["choices"] as? [[String: Any]],
         let first = choices.first,
         let message = first["message"] as? [String: Any],
         let content = message["content"] as? String {
        // Append assistant response to history for continuity
        conversationHistory.append(["role": "assistant", "content": content])
        NSLog("[OpenClaw] Agent result: %@", String(content.prefix(200)))
        lastToolCallStatus = .completed(toolName)
        return .success(content)
      }

      let raw = String(data: data, encoding: .utf8) ?? "OK"
      conversationHistory.append(["role": "assistant", "content": raw])
      NSLog("[OpenClaw] Agent raw: %@", String(raw.prefix(200)))
      lastToolCallStatus = .completed(toolName)
      return .success(raw)
    } catch {
      NSLog("[OpenClaw] Agent error: %@", error.localizedDescription)
      lastToolCallStatus = .failed(toolName, error.localizedDescription)
      return .failure("Agent error: \(error.localizedDescription)")
    }
  }
}
