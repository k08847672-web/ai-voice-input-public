package com.aivoiceinput.android;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.WebSocket;
import okhttp3.WebSocketListener;
import okio.ByteString;

final class AsrSession {
    enum State {
        IDLE,
        CONNECTING,
        RECORDING,
        FINALIZING
    }

    interface Callback {
        void onStateChanged(State state, String message);
        void onPartial(String text);
        void onFinal(String text);
        void onError(String message);
    }

    private static final long MAX_QUEUE_BYTES = 8L * 1024L * 1024L;
    private static final int NORMAL_CLOSURE = 1000;
    private static final int CANCEL_CLOSURE = 1001;

    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final OkHttpClient httpClient = new OkHttpClient.Builder()
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build();
    private final PcmRecorder recorder = new PcmRecorder();

    private State state = State.IDLE;
    private Callback callback;
    private WebSocket webSocket;
    private String sessionId;
    private AppSettings settings;
    private String sourceApplication;
    private Context applicationContext;
    private boolean stopRequested;
    private boolean startMessageSent;
    private Runnable readyTimeout;
    private Runnable finalTimeout;
    private Runnable recordingTimeout;

    State state() {
        return state;
    }

    boolean isActive() {
        return state != State.IDLE;
    }

    void start(
            Context context,
            AppSettings settings,
            String token,
            String sourceApplication,
            Callback callback) {
        if (isActive()) {
            return;
        }
        String normalizedToken = token == null ? "" : token.trim();
        if (normalizedToken.isEmpty()) {
            callback.onError("请先在应用设置中保存 ASR Bearer Token");
            return;
        }

        final String serverUrl;
        try {
            serverUrl = ServerUrlValidator.validate(
                    settings.serverUrl,
                    settings.allowInsecurePrivateNetwork);
            validateConfiguration(settings);
            String normalizedSource = sourceApplication == null ? "" : sourceApplication;
            if (normalizedSource.codePointCount(0, normalizedSource.length()) > 255) {
                throw new IllegalArgumentException("来源应用标识不能超过 255 个字符");
            }
        } catch (IllegalArgumentException error) {
            callback.onError(error.getMessage());
            return;
        }

        this.callback = callback;
        this.settings = settings;
        applicationContext = context.getApplicationContext();
        this.sourceApplication = sourceApplication == null ? "" : sourceApplication;
        sessionId = UUID.randomUUID().toString().toLowerCase(Locale.ROOT);
        stopRequested = false;
        startMessageSent = false;
        transition(State.CONNECTING, "正在连接识别服务…");

        Request request = new Request.Builder()
                .url(serverUrl)
                .header("Authorization", "Bearer " + normalizedToken)
                .build();
        String activeSession = sessionId;
        webSocket = httpClient.newWebSocket(request, listener(activeSession));
        readyTimeout = () -> {
            if (activeSession.equals(sessionId)
                    && (state == State.CONNECTING || (state == State.FINALIZING && stopRequested))) {
                fail("连接识别服务超时", activeSession);
            }
        };
        mainHandler.postDelayed(readyTimeout, 8_000);
    }

    void finish() {
        if (state == State.CONNECTING) {
            stopRequested = true;
            transition(State.FINALIZING, finalizingMessage());
            return;
        }
        if (state != State.RECORDING) {
            return;
        }
        recorder.stop();
        transition(State.FINALIZING, finalizingMessage());
        sendStop(sessionId);
    }

    void cancel() {
        if (!isActive()) {
            return;
        }
        cleanup(CANCEL_CLOSURE, "cancelled");
        transition(State.IDLE, "已取消");
    }

    private WebSocketListener listener(String activeSession) {
        return new WebSocketListener() {
            @Override
            public void onOpen(WebSocket socket, Response response) {
                mainHandler.post(() -> handleOpen(socket, activeSession));
            }

            @Override
            public void onMessage(WebSocket socket, String text) {
                mainHandler.post(() -> handleMessage(text, activeSession));
            }

            @Override
            public void onMessage(WebSocket socket, ByteString bytes) {
                mainHandler.post(() -> fail("ASR 返回了不支持的二进制控制消息", activeSession));
            }

            @Override
            public void onClosed(WebSocket socket, int code, String reason) {
                mainHandler.post(() -> {
                    if (activeSession.equals(sessionId) && isActive()) {
                        fail("ASR 连接已断开", activeSession);
                    }
                });
            }

            @Override
            public void onFailure(WebSocket socket, Throwable error, Response response) {
                mainHandler.post(() -> {
                    if (activeSession.equals(sessionId) && isActive()) {
                        fail("无法连接识别服务：" + safeNetworkMessage(error), activeSession);
                    }
                });
            }
        };
    }

    private void handleOpen(WebSocket socket, String activeSession) {
        if (!activeSession.equals(sessionId) || !isActive()) {
            socket.close(CANCEL_CLOSURE, "stale session");
            return;
        }
        try {
            if (!socket.send(startMessage(activeSession))) {
                fail("无法发送 ASR 会话配置", activeSession);
                return;
            }
            startMessageSent = true;
        } catch (JSONException error) {
            fail("无法生成 ASR 会话配置", activeSession);
        }
    }

    private void handleMessage(String text, String activeSession) {
        if (!activeSession.equals(sessionId) || !isActive()) {
            return;
        }
        try {
            JSONObject message = new JSONObject(text);
            String type = message.optString("type", "");
            String serverSessionId = message.optString("session_id", "");
            if (!serverSessionId.isEmpty() && !activeSession.equalsIgnoreCase(serverSessionId)) {
                fail("ASR 返回了错误的会话标识", activeSession);
                return;
            }
            switch (type) {
                case "ready":
                    if (serverSessionId.isEmpty()) {
                        fail("ASR ready 消息缺少会话标识", activeSession);
                    } else {
                        handleReady(activeSession);
                    }
                    break;
                case "partial":
                    handlePartial(message, activeSession);
                    break;
                case "final":
                    handleFinal(message, activeSession);
                    break;
                case "error":
                    String serverMessage = message.optString("message", "识别服务返回未知错误");
                    fail(safeServerMessage(serverMessage), activeSession);
                    break;
                default:
                    fail("ASR 返回了不支持的事件", activeSession);
            }
        } catch (JSONException error) {
            fail("ASR 返回了无效消息", activeSession);
        }
    }

    private void handleReady(String activeSession) {
        removeReadyTimeout();
        if (state == State.FINALIZING && stopRequested) {
            sendStop(activeSession);
            return;
        }
        if (state != State.CONNECTING) {
            fail("ASR ready 消息顺序错误", activeSession);
            return;
        }
        try {
            recorder.start(applicationContext, new PcmRecorder.Listener() {
                @Override
                public void onAudio(byte[] bytes) {
                    WebSocket socket = webSocket;
                    if (!activeSession.equals(sessionId) || socket == null || state != State.RECORDING) {
                        return;
                    }
                    if (socket.queueSize() > MAX_QUEUE_BYTES || !socket.send(ByteString.of(bytes))) {
                        mainHandler.post(() -> fail("网络发送速度不足，音频缓冲已满", activeSession));
                    }
                }

                @Override
                public void onError(String message) {
                    mainHandler.post(() -> fail(message, activeSession));
                }
            });
            transition(State.RECORDING, "正在录音；完成后停止。");
            recordingTimeout = () -> {
                if (activeSession.equals(sessionId) && state == State.RECORDING) {
                    finish();
                }
            };
            mainHandler.postDelayed(recordingTimeout, 180_000);
        } catch (RuntimeException error) {
            fail(error.getMessage() == null ? "无法开始录音" : error.getMessage(), activeSession);
        }
    }

    private void handlePartial(JSONObject message, String activeSession) {
        if (state != State.RECORDING && state != State.FINALIZING) {
            fail("ASR partial 消息顺序错误", activeSession);
            return;
        }
        if (!message.has("text")) {
            fail("ASR partial 消息缺少文字", activeSession);
            return;
        }
        String transcript = message.optString("text", "");
        if (transcript.codePointCount(0, transcript.length()) > 100_000) {
            fail("ASR partial 文字过长", activeSession);
            return;
        }
        callback.onPartial(transcript);
    }

    private void handleFinal(JSONObject message, String activeSession) {
        if (state != State.FINALIZING) {
            fail("ASR final 消息顺序错误", activeSession);
            return;
        }
        if (!message.has("text")) {
            fail("ASR final 消息缺少文字", activeSession);
            return;
        }
        String transcript = message.optString("text", "").trim();
        if (transcript.isEmpty()) {
            fail("没有识别到可插入的文字", activeSession);
            return;
        }
        if (transcript.codePointCount(0, transcript.length()) > 100_000) {
            fail("ASR final 文字过长", activeSession);
            return;
        }

        Callback completion = callback;
        cleanup(NORMAL_CLOSURE, "completed");
        transition(State.IDLE, "识别完成");
        if (completion != null) {
            completion.onFinal(transcript);
        }
    }

    private void sendStop(String activeSession) {
        if (!activeSession.equals(sessionId) || webSocket == null) {
            fail("ASR 连接不可用", activeSession);
            return;
        }
        try {
            JSONObject stop = new JSONObject()
                    .put("type", "stop")
                    .put("session_id", activeSession);
            if (!webSocket.send(stop.toString())) {
                fail("无法发送 ASR 停止消息", activeSession);
                return;
            }
            removeRecordingTimeout();
            int timeoutSeconds = settings.mode == InputMode.FAITHFUL ? 12 : 35;
            finalTimeout = () -> {
                if (activeSession.equals(sessionId) && state == State.FINALIZING) {
                    fail("等待最终识别结果超时", activeSession);
                }
            };
            mainHandler.postDelayed(finalTimeout, timeoutSeconds * 1_000L);
        } catch (JSONException error) {
            fail("无法生成 ASR 停止消息", activeSession);
        }
    }

    private String startMessage(String activeSession) throws JSONException {
        JSONArray hotwords = new JSONArray();
        for (String hotword : settings.hotwords) {
            hotwords.put(hotword);
        }
        JSONObject dictionary = new JSONObject();
        for (Map.Entry<String, String> entry : settings.dictionary.entrySet()) {
            dictionary.put(entry.getKey(), entry.getValue());
        }
        JSONObject configuration = new JSONObject()
                .put("sample_rate", 16_000)
                .put("channels", 1)
                .put("encoding", "pcm_s16le")
                .put("language", settings.language)
                .put("mode", settings.mode.wireValue)
                .put("hotwords", hotwords)
                .put("dictionary", dictionary)
                .put("style", settings.style)
                .put("source_application", sourceApplication);
        return new JSONObject()
                .put("type", "start")
                .put("session_id", activeSession)
                .put("protocol_version", 1)
                .put("config", configuration)
                .toString();
    }

    private static void validateConfiguration(AppSettings settings) {
        int languageLength = settings.language.codePointCount(0, settings.language.length());
        if (languageLength < 2 || languageLength > 32) {
            throw new IllegalArgumentException("识别语言代码长度必须为 2–32 个字符");
        }
        if (settings.hotwords.size() > 500) {
            throw new IllegalArgumentException("热词不能超过 500 个");
        }
        for (String hotword : settings.hotwords) {
            if (hotword.codePointCount(0, hotword.length()) > 100) {
                throw new IllegalArgumentException("单个热词不能超过 100 个字符");
            }
        }
        if (settings.dictionary.size() > 1_000) {
            throw new IllegalArgumentException("个人词典不能超过 1000 条");
        }
        for (Map.Entry<String, String> entry : settings.dictionary.entrySet()) {
            if (entry.getKey().codePointCount(0, entry.getKey().length()) > 100
                    || entry.getValue().codePointCount(0, entry.getValue().length()) > 200) {
                throw new IllegalArgumentException("个人词典条目过长");
            }
        }
        if (settings.style.codePointCount(0, settings.style.length()) > 2_000) {
            throw new IllegalArgumentException("表达风格不能超过 2000 个字符");
        }
    }

    private String finalizingMessage() {
        return settings != null && settings.mode == InputMode.FAITHFUL
                ? "正在等待最终识别结果…"
                : "正在识别并进行 AI 整理…";
    }

    private void fail(String message, String activeSession) {
        if (activeSession == null || !activeSession.equals(sessionId)) {
            return;
        }
        Callback failureCallback = callback;
        cleanup(CANCEL_CLOSURE, "failed");
        transition(State.IDLE, "本次识别失败");
        if (failureCallback != null) {
            failureCallback.onError(message == null || message.isEmpty() ? "本次识别失败" : message);
        }
    }

    private void cleanup(int closeCode, String reason) {
        removeReadyTimeout();
        removeFinalTimeout();
        removeRecordingTimeout();
        recorder.stop();
        WebSocket socket = webSocket;
        webSocket = null;
        String previousSession = sessionId;
        sessionId = null;
        stopRequested = false;
        startMessageSent = false;
        settings = null;
        sourceApplication = null;
        applicationContext = null;
        callback = null;
        if (socket != null && previousSession != null) {
            socket.close(closeCode, reason);
        }
    }

    private void transition(State newState, String message) {
        state = newState;
        Callback activeCallback = callback;
        if (activeCallback != null) {
            activeCallback.onStateChanged(newState, message);
        }
    }

    private void removeReadyTimeout() {
        if (readyTimeout != null) {
            mainHandler.removeCallbacks(readyTimeout);
            readyTimeout = null;
        }
    }

    private void removeFinalTimeout() {
        if (finalTimeout != null) {
            mainHandler.removeCallbacks(finalTimeout);
            finalTimeout = null;
        }
    }

    private void removeRecordingTimeout() {
        if (recordingTimeout != null) {
            mainHandler.removeCallbacks(recordingTimeout);
            recordingTimeout = null;
        }
    }

    private static String safeNetworkMessage(Throwable error) {
        if (error == null || error.getMessage() == null || error.getMessage().isEmpty()) {
            return "网络错误";
        }
        String message = error.getMessage();
        return message.length() > 200 ? message.substring(0, 200) : message;
    }

    private static String safeServerMessage(String message) {
        if (message == null || message.trim().isEmpty()) {
            return "识别服务返回未知错误";
        }
        String normalized = message.trim();
        return normalized.length() > 1_000 ? normalized.substring(0, 1_000) : normalized;
    }
}
