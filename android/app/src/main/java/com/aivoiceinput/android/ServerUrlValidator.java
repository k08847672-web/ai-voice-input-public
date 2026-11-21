package com.aivoiceinput.android;

import java.net.URI;
import java.util.Locale;

final class ServerUrlValidator {
    private ServerUrlValidator() {}

    static String validate(String value, boolean allowInsecurePrivateNetwork) {
        String normalized = value == null ? "" : value.trim();
        final URI uri;
        try {
            uri = URI.create(normalized);
        } catch (IllegalArgumentException error) {
            throw new IllegalArgumentException("ASR 服务地址无效");
        }

        String scheme = uri.getScheme() == null
                ? ""
                : uri.getScheme().toLowerCase(Locale.ROOT);
        String host = uri.getHost() == null
                ? ""
                : uri.getHost().toLowerCase(Locale.ROOT);
        if (host.isEmpty()
                || uri.getUserInfo() != null
                || uri.getQuery() != null
                || uri.getFragment() != null) {
            throw new IllegalArgumentException("ASR 服务地址无效，地址中不能包含凭据、查询或片段");
        }
        if (host.endsWith(".invalid")) {
            throw new IllegalArgumentException("请先填写有效的 ASR 服务地址");
        }
        if ("wss".equals(scheme)) {
            return uri.toString();
        }
        if ("ws".equals(scheme)
                && allowInsecurePrivateNetwork
                && ("localhost".equals(host)
                    || "127.0.0.1".equals(host)
                    || "::1".equals(host)
                    || "[::1]".equals(host)
                    || isTailscaleIpv4(host))) {
            return uri.toString();
        }
        throw new IllegalArgumentException(
                "公网必须使用 wss://；仅可显式允许 localhost 或 Tailscale 私网 ws://");
    }

    private static boolean isTailscaleIpv4(String host) {
        String[] components = host.split("\\.", -1);
        if (components.length != 4) {
            return false;
        }
        int[] octets = new int[4];
        for (int index = 0; index < components.length; index++) {
            try {
                octets[index] = Integer.parseInt(components[index]);
            } catch (NumberFormatException error) {
                return false;
            }
            if (octets[index] < 0 || octets[index] > 255) {
                return false;
            }
        }
        return octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127;
    }
}
