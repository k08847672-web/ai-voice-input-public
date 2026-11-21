package com.aivoiceinput.android;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import org.json.JSONException;
import org.json.JSONObject;

import java.net.URI;
import java.util.LinkedHashMap;
import java.util.Iterator;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;

final class DictionarySyncClient {
    interface Callback {
        void onComplete(String status, String dictionaryText);
    }

    private static final ExecutorService EXECUTOR = Executors.newSingleThreadExecutor();
    private static final AtomicBoolean RUNNING = new AtomicBoolean(false);
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final OkHttpClient HTTP = new OkHttpClient.Builder()
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(12, TimeUnit.SECONDS)
            .build();

    static void schedule(Context context, Callback callback) {
        if (!RUNNING.compareAndSet(false, true)) return;
        Context app = context.getApplicationContext();
        EXECUTOR.execute(() -> {
            String status;
            String dictionaryText = null;
            try {
                Result result = synchronize(app);
                status = result.conflict ? "同一读音冲突，已保留本机修改" : "词典已同步";
                dictionaryText = result.dictionaryText;
            } catch (Exception error) {
                status = "词典同步暂不可用，本地词典不受影响";
            } finally {
                RUNNING.set(false);
            }
            if (callback != null) {
                String finalStatus = status;
                String finalText = dictionaryText;
                MAIN.post(() -> callback.onComplete(finalStatus, finalText));
            }
        });
    }

    private static Result synchronize(Context context) throws Exception {
        AppSettings settings = AppSettings.load(context);
        String token = new SecureTokenStore(context).load().trim();
        if (token.isEmpty()) throw new IllegalStateException("missing token");
        String asrUrl = ServerUrlValidator.validate(
                settings.serverUrl, settings.allowInsecurePrivateNetwork);
        URI asr = URI.create(asrUrl);
        if (!"/v1/asr/stream".equals(asr.getPath())) {
            throw new IllegalStateException("sync requires standard v1 endpoint");
        }
        String scheme = "wss".equalsIgnoreCase(asr.getScheme()) ? "https" : "http";
        URI uri = new URI(scheme, null, asr.getHost(), asr.getPort(),
                "/v1/dictionary", null, null);
        String endpoint = uri.toString();
        SecureProfileStore store = new SecureProfileStore(context);
        for (int attempt = 0; attempt < 3; attempt++) {
            Snapshot remote = fetch(endpoint, token);
            SecureProfileStore.Profile profile = store.load();
            Map<String, String> baseline = decodeMap(profile.syncBaseline);
            Map<String, String> local = AppSettings.parseDictionary(profile.dictionary);
            DictionaryMerge.Result proposed = DictionaryMerge.merge(baseline, local, remote.entries);
            Snapshot saved = remote;
            if (!proposed.entries.equals(remote.entries)) {
                saved = replace(endpoint, token, remote.revision, proposed.entries);
                if (saved == null) continue;
            }
            SecureProfileStore.Profile current = store.load();
            Map<String, String> latest = AppSettings.parseDictionary(current.dictionary);
            DictionaryMerge.Result rebased = DictionaryMerge.merge(local, latest, saved.entries);
            String updatedText = AppSettings.serializeDictionary(rebased.entries);
            store.save(new SecureProfileStore.Profile(
                    current.hotwords, updatedText, current.style,
                    new JSONObject(saved.entries).toString(), saved.revision));
            return new Result(updatedText, proposed.conflict || rebased.conflict);
        }
        throw new IllegalStateException("revision conflict");
    }

    private static Snapshot fetch(String endpoint, String token) throws Exception {
        Request request = new Request.Builder()
                .url(endpoint).header("Authorization", "Bearer " + token)
                .header("Cache-Control", "no-store").build();
        return execute(request, false);
    }

    private static Snapshot replace(
            String endpoint, String token, int revision, Map<String, String> entries
    ) throws Exception {
        JSONObject payload = new JSONObject().put("revision", revision)
                .put("entries", new JSONObject(entries));
        RequestBody body = RequestBody.create(
                MediaType.parse("application/json"), payload.toString());
        Request request = new Request.Builder().url(endpoint)
                .header("Authorization", "Bearer " + token)
                .header("If-Match", Integer.toString(revision))
                .put(body).build();
        return execute(request, true);
    }

    private static Snapshot execute(Request request, boolean allowConflict) throws Exception {
        try (Response response = HTTP.newCall(request).execute()) {
            if (allowConflict && response.code() == 409) return null;
            if (response.code() != 200 || response.body() == null
                    || response.body().contentLength() > 1_200_000) {
                throw new IllegalStateException("sync unavailable");
            }
            byte[] bytes = response.body().bytes();
            if (bytes.length > 1_200_000) throw new IllegalStateException("response too large");
            JSONObject object = new JSONObject(new String(bytes, java.nio.charset.StandardCharsets.UTF_8));
            int revision = object.getInt("revision");
            if (revision < 0) throw new IllegalStateException("invalid revision");
            return new Snapshot(revision, decodeMap(object.getJSONObject("entries")));
        }
    }

    private static Map<String, String> decodeMap(String text) throws JSONException {
        return text.isEmpty() ? new LinkedHashMap<>() : decodeMap(new JSONObject(text));
    }

    private static Map<String, String> decodeMap(JSONObject object) throws JSONException {
        if (object.length() > 1_000) throw new JSONException("too many entries");
        Map<String, String> entries = new LinkedHashMap<>();
        Iterator<String> keys = object.keys();
        while (keys.hasNext()) {
            String spoken = keys.next();
            String written = object.getString(spoken);
            if (spoken.isBlank() || spoken.codePointCount(0, spoken.length()) > 100
                    || written.isBlank() || written.codePointCount(0, written.length()) > 200) {
                throw new JSONException("invalid entry");
            }
            entries.put(spoken, written);
        }
        return entries;
    }

    private static final class Snapshot {
        final int revision;
        final Map<String, String> entries;

        Snapshot(int revision, Map<String, String> entries) {
            this.revision = revision;
            this.entries = entries;
        }
    }

    private static final class Result {
        final String dictionaryText;
        final boolean conflict;

        Result(String dictionaryText, boolean conflict) {
            this.dictionaryText = dictionaryText;
            this.conflict = conflict;
        }
    }
}
