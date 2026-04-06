package com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw

import android.util.Log
import com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini.GeminiConfig
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

class OpenClawBridge {
    companion object {
        private const val TAG = "OpenClawBridge"
        private const val MAX_HISTORY_TURNS = 10
    }

    private val _lastToolCallStatus = MutableStateFlow<ToolCallStatus>(ToolCallStatus.Idle)
    val lastToolCallStatus: StateFlow<ToolCallStatus> = _lastToolCallStatus.asStateFlow()

    private val _connectionState = MutableStateFlow<OpenClawConnectionState>(OpenClawConnectionState.NotConfigured)
    val connectionState: StateFlow<OpenClawConnectionState> = _connectionState.asStateFlow()

    fun setToolCallStatus(status: ToolCallStatus) {
        _lastToolCallStatus.value = status
    }

    private val client = OkHttpClient.Builder()
        .readTimeout(120, TimeUnit.SECONDS)
        .connectTimeout(10, TimeUnit.SECONDS)
        .build()

    private val pingClient = OkHttpClient.Builder()
        .readTimeout(5, TimeUnit.SECONDS)
        .connectTimeout(5, TimeUnit.SECONDS)
        .build()

    private var sessionKey: String = "agent:main:glass"
    private val conversationHistory = mutableListOf<JSONObject>()

    suspend fun checkConnection() = withContext(Dispatchers.IO) {
        if (!GeminiConfig.isOpenClawConfigured) {
            _connectionState.value = OpenClawConnectionState.NotConfigured
            return@withContext
        }
        _connectionState.value = OpenClawConnectionState.Checking

        // Step 1: Check gateway health endpoint
        val healthUrl = "${GeminiConfig.openClawHost}:${GeminiConfig.openClawPort}/health"
        try {
            val healthRequest = Request.Builder()
                .url(healthUrl)
                .get()
                .build()

            val healthResponse = pingClient.newCall(healthRequest).execute()
            val healthCode = healthResponse.code
            healthResponse.close()

            if (healthCode !in 200..299) {
                _connectionState.value = OpenClawConnectionState.Unreachable("Gateway not running (HTTP $healthCode)")
                Log.d(TAG, "Gateway health check failed: HTTP $healthCode")
                return@withContext
            }
        } catch (e: Exception) {
            _connectionState.value = OpenClawConnectionState.Unreachable("Gateway unreachable: ${e.message}")
            Log.d(TAG, "Gateway unreachable: ${e.message}")
            return@withContext
        }

        // Step 2: Verify chat completions endpoint is enabled
        val chatUrl = "${GeminiConfig.openClawHost}:${GeminiConfig.openClawPort}/v1/chat/completions"
        try {
            val chatRequest = Request.Builder()
                .url(chatUrl)
                .get()
                .addHeader("Authorization", "Bearer ${GeminiConfig.openClawGatewayToken}")
                .addHeader("x-openclaw-message-channel", "glass")
                .build()

            val chatResponse = pingClient.newCall(chatRequest).execute()
            val code = chatResponse.code
            chatResponse.close()

            when (code) {
                in 200..299, 405 -> {
                    // 405 Method Not Allowed on GET is expected — endpoint exists and is enabled
                    _connectionState.value = OpenClawConnectionState.Connected
                    Log.d(TAG, "Gateway connected (HTTP $code)")
                }
                401, 403 -> {
                    _connectionState.value = OpenClawConnectionState.Unreachable(
                        "Authentication failed (HTTP $code) — check your gateway token"
                    )
                    Log.d(TAG, "Auth failed: HTTP $code")
                }
                404 -> {
                    _connectionState.value = OpenClawConnectionState.Unreachable(
                        "chatCompletions endpoint disabled — enable it in openclaw.json"
                    )
                    Log.d(TAG, "Endpoint disabled: HTTP 404. Set gateway.http.endpoints.chatCompletions.enabled = true in ~/.openclaw/openclaw.json")
                }
                else -> {
                    _connectionState.value = OpenClawConnectionState.Unreachable("Unexpected response (HTTP $code)")
                    Log.d(TAG, "Unexpected status: HTTP $code")
                }
            }
        } catch (e: Exception) {
            _connectionState.value = OpenClawConnectionState.Unreachable(e.message ?: "Unknown error")
            Log.d(TAG, "Chat endpoint check failed: ${e.message}")
        }
    }

    fun resetSession() {
        conversationHistory.clear()
        Log.d(TAG, "Session reset (key retained: $sessionKey)")
    }

    suspend fun delegateTask(
        task: String,
        toolName: String = "execute"
    ): ToolResult = withContext(Dispatchers.IO) {
        _lastToolCallStatus.value = ToolCallStatus.Executing(toolName)

        val url = "${GeminiConfig.openClawHost}:${GeminiConfig.openClawPort}/v1/chat/completions"

        // Append user message
        conversationHistory.add(JSONObject().apply {
            put("role", "user")
            put("content", task)
        })

        // Trim history
        if (conversationHistory.size > MAX_HISTORY_TURNS * 2) {
            val trimmed = conversationHistory.takeLast(MAX_HISTORY_TURNS * 2)
            conversationHistory.clear()
            conversationHistory.addAll(trimmed)
        }

        Log.d(TAG, "Sending ${conversationHistory.size} messages in conversation")

        try {
            val messagesArray = JSONArray()
            for (msg in conversationHistory) {
                messagesArray.put(msg)
            }

            val body = JSONObject().apply {
                put("model", "openclaw")
                put("messages", messagesArray)
                put("stream", false)
            }

            val request = Request.Builder()
                .url(url)
                .post(body.toString().toRequestBody("application/json".toMediaType()))
                .addHeader("Authorization", "Bearer ${GeminiConfig.openClawGatewayToken}")
                .addHeader("Content-Type", "application/json")
                .addHeader("x-openclaw-session-key", sessionKey)
                .addHeader("x-openclaw-message-channel", "glass")
                .addHeader("x-openclaw-scopes", "operator.write")
                .build()

            val response = client.newCall(request).execute()
            val responseBody = response.body?.string() ?: ""
            val statusCode = response.code
            response.close()

            if (statusCode !in 200..299) {
                Log.d(TAG, "Chat failed: HTTP $statusCode - ${responseBody.take(200)}")
                _lastToolCallStatus.value = ToolCallStatus.Failed(toolName, "HTTP $statusCode")
                return@withContext ToolResult.Failure("Agent returned HTTP $statusCode")
            }

            val json = JSONObject(responseBody)
            val choices = json.optJSONArray("choices")
            val content = choices?.optJSONObject(0)
                ?.optJSONObject("message")
                ?.optString("content", "")

            if (!content.isNullOrEmpty()) {
                conversationHistory.add(JSONObject().apply {
                    put("role", "assistant")
                    put("content", content)
                })
                Log.d(TAG, "Agent result: ${content.take(200)}")
                _lastToolCallStatus.value = ToolCallStatus.Completed(toolName)
                return@withContext ToolResult.Success(content)
            }

            conversationHistory.add(JSONObject().apply {
                put("role", "assistant")
                put("content", responseBody)
            })
            Log.d(TAG, "Agent raw: ${responseBody.take(200)}")
            _lastToolCallStatus.value = ToolCallStatus.Completed(toolName)
            return@withContext ToolResult.Success(responseBody)
        } catch (e: Exception) {
            Log.e(TAG, "Agent error: ${e.message}")
            _lastToolCallStatus.value = ToolCallStatus.Failed(toolName, e.message ?: "Unknown")
            return@withContext ToolResult.Failure("Agent error: ${e.message}")
        }
    }

}
