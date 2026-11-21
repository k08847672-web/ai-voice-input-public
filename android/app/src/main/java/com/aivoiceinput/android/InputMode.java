package com.aivoiceinput.android;

enum InputMode {
    FAITHFUL("faithful", "忠实听写"),
    SMART("smart", "智能整理"),
    COMMAND("command", "指令模式");

    final String wireValue;
    final String displayName;

    InputMode(String wireValue, String displayName) {
        this.wireValue = wireValue;
        this.displayName = displayName;
    }

    static InputMode fromWireValue(String value) {
        for (InputMode mode : values()) {
            if (mode.wireValue.equals(value)) {
                return mode;
            }
        }
        return SMART;
    }

    InputMode next() {
        InputMode[] modes = values();
        return modes[(ordinal() + 1) % modes.length];
    }
}
