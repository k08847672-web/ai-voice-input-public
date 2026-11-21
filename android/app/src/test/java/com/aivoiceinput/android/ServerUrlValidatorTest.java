package com.aivoiceinput.android;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;

import org.junit.Test;

public final class ServerUrlValidatorTest {
    @Test
    public void acceptsSecureWebSocket() {
        assertEquals(
                "wss://asr.example.com/v1/asr/stream",
                ServerUrlValidator.validate("wss://asr.example.com/v1/asr/stream", false));
    }

    @Test
    public void acceptsExplicitTailscaleWebSocket() {
        assertEquals(
                "ws://100.86.28.63:19001/v1/asr/stream",
                ServerUrlValidator.validate(
                        "ws://100.86.28.63:19001/v1/asr/stream", true));
    }

    @Test
    public void acceptsExplicitIpv6Localhost() {
        assertEquals(
                "ws://[::1]:8765/v1/asr/stream",
                ServerUrlValidator.validate("ws://[::1]:8765/v1/asr/stream", true));
    }

    @Test
    public void rejectsTailscaleWebSocketWithoutOptIn() {
        assertThrows(
                IllegalArgumentException.class,
                () -> ServerUrlValidator.validate(
                        "ws://100.86.28.63:19001/v1/asr/stream", false));
    }

    @Test
    public void rejectsPublicCleartextAndEmbeddedCredentials() {
        assertThrows(
                IllegalArgumentException.class,
                () -> ServerUrlValidator.validate("ws://203.0.113.1/asr", true));
        assertThrows(
                IllegalArgumentException.class,
                () -> ServerUrlValidator.validate("wss://user:secret@example.com/asr", false));
    }

    @Test
    public void rejectsPlaceholderAndQuery() {
        assertThrows(
                IllegalArgumentException.class,
                () -> ServerUrlValidator.validate("wss://asr.invalid/asr", false));
        assertThrows(
                IllegalArgumentException.class,
                () -> ServerUrlValidator.validate("wss://asr.example.com/asr?token=secret", false));
    }
}
