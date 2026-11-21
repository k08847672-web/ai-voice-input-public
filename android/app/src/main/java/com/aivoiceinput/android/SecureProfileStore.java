package com.aivoiceinput.android;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import org.json.JSONObject;

import java.nio.charset.StandardCharsets;
import java.security.KeyStore;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

final class SecureProfileStore {
    static final class Profile {
        final String hotwords;
        final String dictionary;
        final String style;
        final String syncBaseline;
        final int syncRevision;

        Profile(String hotwords, String dictionary, String style) {
            this(hotwords, dictionary, style, "", 0);
        }

        Profile(String hotwords, String dictionary, String style, String syncBaseline, int syncRevision) {
            this.hotwords = hotwords;
            this.dictionary = dictionary;
            this.style = style;
            this.syncBaseline = syncBaseline;
            this.syncRevision = syncRevision;
        }
    }

    private static final String KEYSTORE_PROVIDER = "AndroidKeyStore";
    private static final String KEY_ALIAS = "ai_voice_input_private_profile_v1";
    private static final String CIPHERTEXT_KEY = "private_profile_ciphertext";
    private static final String IV_KEY = "private_profile_iv";

    private final Context context;

    SecureProfileStore(Context context) {
        this.context = context.getApplicationContext();
    }

    Profile load() throws Exception {
        SharedPreferences preferences = AppSettings.preferences(context);
        String ciphertextValue = preferences.getString(CIPHERTEXT_KEY, null);
        String ivValue = preferences.getString(IV_KEY, null);
        if (ciphertextValue == null && ivValue == null) {
            return new Profile(
                    preferences.getString("hotwords", ""),
                    preferences.getString("dictionary", ""),
                    preferences.getString("style", ""));
        }
        if (ciphertextValue == null || ivValue == null) {
            throw new IllegalStateException("个人资料加密数据不完整，请明确重置后重新配置");
        }

        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(
                Cipher.DECRYPT_MODE,
                existingKey(),
                new GCMParameterSpec(128, Base64.decode(ivValue, Base64.NO_WRAP)));
        cipher.updateAAD(aad());
        byte[] plaintext = cipher.doFinal(Base64.decode(ciphertextValue, Base64.NO_WRAP));
        JSONObject object = new JSONObject(new String(plaintext, StandardCharsets.UTF_8));
        return new Profile(
                object.optString("hotwords", ""),
                object.optString("dictionary", ""),
                object.optString("style", ""),
                object.optString("sync_baseline", ""),
                object.optInt("sync_revision", 0));
    }

    void save(Profile profile) throws Exception {
        JSONObject object = new JSONObject()
                .put("hotwords", profile.hotwords)
                .put("dictionary", profile.dictionary)
                .put("style", profile.style)
                .put("sync_baseline", profile.syncBaseline)
                .put("sync_revision", profile.syncRevision);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, existingOrCreateKey());
        cipher.updateAAD(aad());
        byte[] ciphertext = cipher.doFinal(
                object.toString().getBytes(StandardCharsets.UTF_8));
        AppSettings.preferences(context).edit()
                .putString(IV_KEY, Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP))
                .putString(CIPHERTEXT_KEY, Base64.encodeToString(ciphertext, Base64.NO_WRAP))
                .remove("hotwords")
                .remove("dictionary")
                .remove("style")
                .apply();
    }

    void reset() throws Exception {
        AppSettings.preferences(context).edit()
                .remove(CIPHERTEXT_KEY)
                .remove(IV_KEY)
                .remove("hotwords")
                .remove("dictionary")
                .remove("style")
                .apply();
        KeyStore keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER);
        keyStore.load(null);
        if (keyStore.containsAlias(KEY_ALIAS)) {
            keyStore.deleteEntry(KEY_ALIAS);
        }
    }

    private SecretKey existingKey() throws Exception {
        KeyStore keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER);
        keyStore.load(null);
        SecretKey key = (SecretKey) keyStore.getKey(KEY_ALIAS, null);
        if (key == null) {
            throw new IllegalStateException("个人资料加密密钥不可用，请明确重置后重新配置");
        }
        return key;
    }

    private SecretKey existingOrCreateKey() throws Exception {
        KeyStore keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER);
        keyStore.load(null);
        SecretKey existing = (SecretKey) keyStore.getKey(KEY_ALIAS, null);
        if (existing != null) {
            return existing;
        }

        KeyGenerator generator = KeyGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_AES,
                KEYSTORE_PROVIDER);
        generator.init(new KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build());
        return generator.generateKey();
    }

    private byte[] aad() {
        return (context.getPackageName() + ":private-profile-v1")
                .getBytes(StandardCharsets.UTF_8);
    }
}
