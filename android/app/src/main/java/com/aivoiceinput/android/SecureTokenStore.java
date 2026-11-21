package com.aivoiceinput.android;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import java.nio.charset.StandardCharsets;
import java.security.KeyStore;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

final class SecureTokenStore {
    private static final String KEYSTORE_PROVIDER = "AndroidKeyStore";
    private static final String KEY_ALIAS = "ai_voice_input_asr_token_v1";
    private static final String TOKEN_CIPHERTEXT = "token_ciphertext";
    private static final String TOKEN_IV = "token_iv";

    private final Context context;

    SecureTokenStore(Context context) {
        this.context = context.getApplicationContext();
    }

    String load() throws Exception {
        SharedPreferences preferences = AppSettings.preferences(context);
        String ciphertextValue = preferences.getString(TOKEN_CIPHERTEXT, null);
        String ivValue = preferences.getString(TOKEN_IV, null);
        if (ciphertextValue == null && ivValue == null) {
            return "";
        }
        if (ciphertextValue == null || ivValue == null) {
            throw new IllegalStateException("Token 加密数据不完整，请在设置中重新保存 Token");
        }

        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(
                Cipher.DECRYPT_MODE,
                existingKey(),
                new GCMParameterSpec(128, Base64.decode(ivValue, Base64.NO_WRAP)));
        cipher.updateAAD(context.getPackageName().getBytes(StandardCharsets.UTF_8));
        byte[] plaintext = cipher.doFinal(Base64.decode(ciphertextValue, Base64.NO_WRAP));
        return new String(plaintext, StandardCharsets.UTF_8);
    }

    void save(String value) throws Exception {
        String normalized = value == null ? "" : value.trim();
        SharedPreferences preferences = AppSettings.preferences(context);
        if (normalized.isEmpty()) {
            preferences.edit().remove(TOKEN_CIPHERTEXT).remove(TOKEN_IV).apply();
            return;
        }

        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, existingOrCreateKey());
        cipher.updateAAD(context.getPackageName().getBytes(StandardCharsets.UTF_8));
        byte[] ciphertext = cipher.doFinal(normalized.getBytes(StandardCharsets.UTF_8));
        preferences.edit()
                .putString(TOKEN_IV, Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP))
                .putString(TOKEN_CIPHERTEXT, Base64.encodeToString(ciphertext, Base64.NO_WRAP))
                .apply();
    }

    private SecretKey existingKey() throws Exception {
        KeyStore keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER);
        keyStore.load(null);
        SecretKey key = (SecretKey) keyStore.getKey(KEY_ALIAS, null);
        if (key == null) {
            throw new IllegalStateException("Token 加密密钥不可用，请在设置中重新保存 Token");
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
}
