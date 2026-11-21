package com.aivoiceinput.android;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

final class AppSettings {
    static final String DEFAULT_SERVER_URL =
            "ws://100.91.11.111:19001/v1/asr/stream";
    private static final String PREVIOUS_SERVER_URL =
            "ws://100.86.28.63:19001/v1/asr/stream";

    enum ActivationMode {
        HOLD("hold", "按住说话"),
        TOGGLE("toggle", "按一下开始，再按一下结束");

        final String storedValue;
        final String displayName;

        ActivationMode(String storedValue, String displayName) {
            this.storedValue = storedValue;
            this.displayName = displayName;
        }

        static ActivationMode fromStoredValue(String value) {
            return TOGGLE.storedValue.equals(value) ? TOGGLE : HOLD;
        }
    }

    final String serverUrl;
    final String language;
    final InputMode mode;
    final ActivationMode activationMode;
    final boolean allowInsecurePrivateNetwork;
    final List<String> hotwords;
    final Map<String, String> dictionary;
    final String style;

    AppSettings(
            String serverUrl,
            String language,
            InputMode mode,
            ActivationMode activationMode,
            boolean allowInsecurePrivateNetwork,
            List<String> hotwords,
            Map<String, String> dictionary,
            String style) {
        this.serverUrl = serverUrl;
        this.language = language;
        this.mode = mode;
        this.activationMode = activationMode;
        this.allowInsecurePrivateNetwork = allowInsecurePrivateNetwork;
        this.hotwords = Collections.unmodifiableList(new ArrayList<>(hotwords));
        this.dictionary = Collections.unmodifiableMap(new LinkedHashMap<>(dictionary));
        this.style = style;
    }

    AppSettings withMode(InputMode newMode) {
        return new AppSettings(
                serverUrl,
                language,
                newMode,
                activationMode,
                allowInsecurePrivateNetwork,
                hotwords,
                dictionary,
                style);
    }

    static AppSettings defaults() {
        return new AppSettings(
                DEFAULT_SERVER_URL,
                "zh-CN",
                InputMode.SMART,
                ActivationMode.HOLD,
                false,
                Collections.emptyList(),
                Collections.emptyMap(),
                "");
    }

    static AppSettings load(Context context) throws Exception {
        SharedPreferences preferences = preferences(context);
        SecureProfileStore.Profile profile = new SecureProfileStore(context).load();
        String serverUrl = preferences.getString("server_url", DEFAULT_SERVER_URL);
        if (PREVIOUS_SERVER_URL.equals(serverUrl)) {
            serverUrl = DEFAULT_SERVER_URL;
            preferences.edit().putString("server_url", serverUrl).apply();
        }
        return new AppSettings(
                serverUrl,
                preferences.getString("language", "zh-CN"),
                InputMode.fromWireValue(preferences.getString("mode", InputMode.SMART.wireValue)),
                ActivationMode.fromStoredValue(
                        preferences.getString("activation_mode", ActivationMode.HOLD.storedValue)),
                preferences.getBoolean("allow_insecure_private_network", false),
                parseLines(profile.hotwords),
                parseDictionary(profile.dictionary),
                profile.style);
    }

    void save(Context context) throws Exception {
        SecureProfileStore profileStore = new SecureProfileStore(context);
        SecureProfileStore.Profile prior = profileStore.load();
        profileStore.save(new SecureProfileStore.Profile(
                String.join("\n", hotwords),
                serializeDictionary(dictionary),
                style,
                prior.syncBaseline,
                prior.syncRevision));
        preferences(context)
                .edit()
                .putString("server_url", serverUrl)
                .putString("language", language)
                .putString("mode", mode.wireValue)
                .putString("activation_mode", activationMode.storedValue)
                .putBoolean("allow_insecure_private_network", allowInsecurePrivateNetwork)
                .apply();
    }

    static SharedPreferences preferences(Context context) {
        return context.getSharedPreferences("voice_input_settings_v1", Context.MODE_PRIVATE);
    }

    static List<String> parseLines(String value) {
        List<String> result = new ArrayList<>();
        if (value == null) {
            return result;
        }
        for (String line : value.split("\\R")) {
            String normalized = line.trim();
            if (!normalized.isEmpty() && !result.contains(normalized)) {
                result.add(normalized);
            }
        }
        return result;
    }

    static Map<String, String> parseDictionary(String value) {
        Map<String, String> result = new LinkedHashMap<>();
        if (value == null) {
            return result;
        }
        for (String line : value.split("\\R")) {
            int separator = line.indexOf('=');
            if (separator <= 0) {
                continue;
            }
            String spoken = line.substring(0, separator).trim();
            String written = line.substring(separator + 1).trim();
            if (!spoken.isEmpty() && !written.isEmpty()) {
                result.put(spoken, written);
            }
        }
        return result;
    }

    static String serializeDictionary(Map<String, String> dictionary) {
        StringBuilder result = new StringBuilder();
        for (Map.Entry<String, String> entry : dictionary.entrySet()) {
            if (result.length() > 0) {
                result.append('\n');
            }
            result.append(entry.getKey()).append('=').append(entry.getValue());
        }
        return result.toString();
    }
}
