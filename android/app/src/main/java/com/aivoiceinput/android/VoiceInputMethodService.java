package com.aivoiceinput.android;

import android.Manifest;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.inputmethodservice.InputMethodService;
import android.os.Build;
import android.text.InputType;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowInsets;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

public final class VoiceInputMethodService extends InputMethodService {
    private final AsrSession asrSession = new AsrSession();

    private LinearLayout rootView;
    private TextView statusView;
    private TextView transcriptView;
    private Button modeButton;
    private Button microphoneButton;
    private Button insertButton;
    private AppSettings settings;
    private EditorInfo currentEditor;
    private InputConnection sessionConnection;
    private String sessionPackage;
    private String pendingFinal;
    private boolean secureInput;
    private boolean settingsAvailable;

    @Override
    public View onCreateInputView() {
        rootView = new LinearLayout(this);
        rootView.setOrientation(LinearLayout.VERTICAL);
        rootView.setPadding(dp(10), dp(8), dp(10), dp(8));
        rootView.setBackgroundResource(com.aivoiceinput.android.R.drawable.ime_panel_background);
        rootView.setOnApplyWindowInsetsListener((view, insets) -> {
            // Ancestors may consume navigation insets before dispatching to the keyboard content.
            WindowInsets windowInsets = view.getRootWindowInsets();
            applyNavigationPadding(windowInsets == null ? insets : windowInsets);
            return insets;
        });

        LinearLayout topRow = horizontalRow();
        modeButton = smallButton("");
        modeButton.setOnClickListener(view -> cycleMode());
        topRow.addView(modeButton, weighted(1.4f));

        Button settingsButton = smallButton("⚙ 设置");
        settingsButton.setContentDescription("打开 AI语音输入法设置");
        settingsButton.setOnClickListener(view -> openSettings());
        topRow.addView(settingsButton, weighted(1));

        Button switchButton = smallButton("🌐 切换");
        switchButton.setContentDescription("切换到下一个输入法");
        switchButton.setOnClickListener(view -> {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                if (!switchToNextInputMethod(false)) {
                    showInputMethodPicker();
                }
            } else {
                showInputMethodPicker();
            }
        });
        topRow.addView(switchButton, weighted(1));
        rootView.addView(topRow, matchWidth());

        statusView = new TextView(this);
        statusView.setTextSize(14);
        statusView.setTextColor(Color.rgb(45, 55, 75));
        statusView.setGravity(Gravity.CENTER);
        statusView.setPadding(dp(4), dp(5), dp(4), dp(3));
        rootView.addView(statusView, matchWidth());

        transcriptView = new TextView(this);
        transcriptView.setTextSize(17);
        transcriptView.setTextColor(Color.rgb(23, 32, 51));
        transcriptView.setGravity(Gravity.CENTER);
        transcriptView.setMinHeight(dp(52));
        transcriptView.setMaxLines(3);
        transcriptView.setPadding(dp(6), dp(4), dp(6), dp(4));
        rootView.addView(transcriptView, matchWidth());

        insertButton = smallButton("插入保留文字");
        insertButton.setVisibility(View.GONE);
        insertButton.setOnClickListener(view -> retryPendingInsertion());
        rootView.addView(insertButton, matchWidth());

        LinearLayout actionRow = horizontalRow();
        Button deleteButton = smallButton("⌫");
        deleteButton.setTextSize(22);
        deleteButton.setContentDescription("删除前一个字符");
        deleteButton.setOnClickListener(view -> deletePreviousCharacter());
        actionRow.addView(deleteButton, weighted(0.75f));

        microphoneButton = smallButton("");
        microphoneButton.setTextSize(18);
        microphoneButton.setTextColor(Color.WHITE);
        microphoneButton.setBackgroundTintList(ColorStateList.valueOf(Color.rgb(49, 87, 213)));
        microphoneButton.setContentDescription("开始或结束语音输入");
        actionRow.addView(microphoneButton, weighted(2.2f));

        Button enterButton = smallButton("↵");
        enterButton.setTextSize(22);
        enterButton.setContentDescription("换行");
        enterButton.setOnClickListener(view -> commitText("\n"));
        actionRow.addView(enterButton, weighted(0.75f));
        rootView.addView(actionRow, matchWidth());

        refreshSettingsAndControls();
        return rootView;
    }

    @Override
    public void onStartInput(EditorInfo attribute, boolean restarting) {
        super.onStartInput(attribute, restarting);
        if (asrSession.isActive()) {
            asrSession.cancel();
        }
        currentEditor = attribute;
        sessionConnection = null;
        sessionPackage = null;
        secureInput = isPasswordField(attribute);
        pendingFinal = null;
        refreshSettingsAndControls();
    }

    @Override
    public void onStartInputView(EditorInfo info, boolean restarting) {
        super.onStartInputView(info, restarting);
        currentEditor = info;
        secureInput = isPasswordField(info);
        refreshSettingsAndControls();
        DictionarySyncClient.schedule(this, (status, dictionaryText) -> {
            if (rootView != null && !asrSession.isActive()) {
                refreshSettingsAndControls();
            }
        });
        if (rootView != null) {
            rootView.post(() -> {
                if (rootView == null || !rootView.isAttachedToWindow()) return;
                applyNavigationPadding(rootView.getRootWindowInsets());
                rootView.requestApplyInsets();
            });
        }
    }

    private void applyNavigationPadding(WindowInsets insets) {
        if (rootView == null || insets == null) return;
        int left, right, bottom;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            android.graphics.Insets navigation = insets.getInsetsIgnoringVisibility(
                    WindowInsets.Type.navigationBars() | WindowInsets.Type.displayCutout());
            left = navigation.left;
            right = navigation.right;
            bottom = navigation.bottom;
        } else {
            left = insets.getSystemWindowInsetLeft();
            right = insets.getSystemWindowInsetRight();
            bottom = insets.getSystemWindowInsetBottom();
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            bottom = Math.max(bottom, insets.getMandatorySystemGestureInsets().bottom);
        }
        // Always start from the design spacing, never the previous (already inset) padding.
        rootView.setPadding(dp(10) + left, dp(8), dp(10) + right, dp(8) + bottom);
    }

    @Override
    public void onFinishInputView(boolean finishingInput) {
        if (asrSession.isActive()) {
            asrSession.cancel();
        }
        sessionConnection = null;
        sessionPackage = null;
        super.onFinishInputView(finishingInput);
    }

    @Override
    public void onDestroy() {
        asrSession.cancel();
        super.onDestroy();
    }

    @Override
    public boolean onEvaluateFullscreenMode() {
        return false;
    }

    private void refreshSettingsAndControls() {
        String settingsError = null;
        try {
            settings = AppSettings.load(this);
            settingsAvailable = true;
        } catch (Exception error) {
            settings = AppSettings.defaults();
            settingsAvailable = false;
            settingsError = error.getMessage() == null
                    ? "无法读取加密的个人资料"
                    : error.getMessage();
        }
        if (rootView == null) {
            return;
        }
        modeButton.setText(settings.mode.displayName);
        configureMicrophoneGesture();
        insertButton.setVisibility(pendingFinal == null ? View.GONE : View.VISIBLE);
        if (!settingsAvailable) {
            statusView.setText(settingsError);
            transcriptView.setText("请打开设置并明确重置损坏的加密资料");
            microphoneButton.setEnabled(false);
        } else if (secureInput) {
            statusView.setText("安全输入框已禁用语音录音");
            transcriptView.setText("请切换到系统键盘输入密码");
            microphoneButton.setEnabled(false);
        } else if (!asrSession.isActive()) {
            statusView.setText("就绪 · " + settings.mode.displayName);
            if (pendingFinal == null) {
                transcriptView.setText("说话过程中会显示实时识别文字");
            }
            microphoneButton.setEnabled(true);
        }
        updateMicrophoneButton(asrSession.state());
    }

    private void configureMicrophoneGesture() {
        microphoneButton.setOnClickListener(null);
        microphoneButton.setOnTouchListener(null);
        if (settings.activationMode == AppSettings.ActivationMode.HOLD) {
            microphoneButton.setOnTouchListener((view, event) -> {
                switch (event.getActionMasked()) {
                    case MotionEvent.ACTION_DOWN:
                        view.performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP);
                        startVoiceInput();
                        return true;
                    case MotionEvent.ACTION_UP:
                        if (asrSession.state() == AsrSession.State.CONNECTING
                                || asrSession.state() == AsrSession.State.RECORDING) {
                            asrSession.finish();
                        }
                        view.performClick();
                        return true;
                    case MotionEvent.ACTION_CANCEL:
                        asrSession.cancel();
                        showIdleStatus("已取消");
                        return true;
                    default:
                        return true;
                }
            });
        } else {
            microphoneButton.setOnClickListener(view -> {
                if (asrSession.state() == AsrSession.State.CONNECTING
                        || asrSession.state() == AsrSession.State.RECORDING) {
                    asrSession.finish();
                } else if (asrSession.state() == AsrSession.State.FINALIZING) {
                    asrSession.cancel();
                    showIdleStatus("已取消");
                } else {
                    startVoiceInput();
                }
            });
        }
    }

    private void startVoiceInput() {
        if (!settingsAvailable || secureInput || asrSession.isActive()) {
            return;
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED) {
            statusView.setText("请先在 AI语音输入法应用中允许麦克风权限");
            openSettings();
            return;
        }

        final String token;
        try {
            token = new SecureTokenStore(this).load();
        } catch (Exception error) {
            showError(error.getMessage() == null ? "无法读取加密 Token" : error.getMessage());
            return;
        }
        sessionConnection = getCurrentInputConnection();
        sessionPackage = currentEditor == null || currentEditor.packageName == null
                ? ""
                : currentEditor.packageName;
        pendingFinal = null;
        insertButton.setVisibility(View.GONE);
        transcriptView.setText("");
        asrSession.start(this, settings, token, sessionPackage, new AsrSession.Callback() {
            @Override
            public void onStateChanged(AsrSession.State state, String message) {
                statusView.setText(message);
                updateMicrophoneButton(state);
            }

            @Override
            public void onPartial(String text) {
                transcriptView.setText(text);
            }

            @Override
            public void onFinal(String text) {
                insertFinal(text);
            }

            @Override
            public void onError(String message) {
                showError(message);
            }
        });
    }

    private void insertFinal(String text) {
        boolean sameApplication = currentEditor != null
                && currentEditor.packageName != null
                && currentEditor.packageName.equals(sessionPackage);
        boolean inserted = sameApplication
                && !secureInput
                && sessionConnection != null
                && sessionConnection.commitText(text, 1);
        sessionConnection = null;
        sessionPackage = null;
        transcriptView.setText(text);
        if (inserted) {
            pendingFinal = null;
            insertButton.setVisibility(View.GONE);
            statusView.setText("已插入 " + text.codePointCount(0, text.length()) + " 个字");
        } else {
            pendingFinal = text;
            insertButton.setVisibility(View.VISIBLE);
            statusView.setText("原输入目标已失效；文字只保留在键盘内存中，可点击重试插入");
        }
        updateMicrophoneButton(AsrSession.State.IDLE);
    }

    private void retryPendingInsertion() {
        if (pendingFinal == null || secureInput) {
            return;
        }
        InputConnection connection = getCurrentInputConnection();
        if (connection != null && connection.commitText(pendingFinal, 1)) {
            int count = pendingFinal.codePointCount(0, pendingFinal.length());
            pendingFinal = null;
            insertButton.setVisibility(View.GONE);
            statusView.setText("已插入 " + count + " 个字");
        } else {
            statusView.setText("仍无法插入，请确认光标位于可编辑输入框");
        }
    }

    private void cycleMode() {
        if (!settingsAvailable || asrSession.isActive()) {
            return;
        }
        settings = settings.withMode(settings.mode.next());
        try {
            settings.save(this);
            modeButton.setText(settings.mode.displayName);
            statusView.setText("已切换为" + settings.mode.displayName);
        } catch (Exception error) {
            settingsAvailable = false;
            showError(error.getMessage() == null ? "无法保存加密设置" : error.getMessage());
            microphoneButton.setEnabled(false);
        }
    }

    private void deletePreviousCharacter() {
        InputConnection connection = getCurrentInputConnection();
        if (connection != null && !connection.deleteSurroundingText(1, 0)) {
            connection.sendKeyEvent(new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DEL));
            connection.sendKeyEvent(new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DEL));
        }
    }

    private void commitText(String text) {
        if (!secureInput) {
            InputConnection connection = getCurrentInputConnection();
            if (connection != null) {
                connection.commitText(text, 1);
            }
        }
    }

    private void openSettings() {
        Intent intent = new Intent(this, MainActivity.class);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        startActivity(intent);
    }

    private void showInputMethodPicker() {
        InputMethodManager manager =
                (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
        manager.showInputMethodPicker();
    }

    private void showError(String message) {
        statusView.setText(message == null || message.isEmpty() ? "本次识别失败" : message);
        transcriptView.setText("");
        updateMicrophoneButton(AsrSession.State.IDLE);
    }

    private void showIdleStatus(String message) {
        statusView.setText(message);
        transcriptView.setText("");
        updateMicrophoneButton(AsrSession.State.IDLE);
    }

    private void updateMicrophoneButton(AsrSession.State state) {
        if (microphoneButton == null || settings == null) {
            return;
        }
        switch (state) {
            case CONNECTING:
                microphoneButton.setText("连接中…");
                break;
            case RECORDING:
                microphoneButton.setText(
                        settings.activationMode == AppSettings.ActivationMode.HOLD
                                ? "松开结束"
                                : "点击结束");
                break;
            case FINALIZING:
                microphoneButton.setText("处理中…");
                break;
            case IDLE:
            default:
                microphoneButton.setText(
                        settings.activationMode == AppSettings.ActivationMode.HOLD
                                ? "按住说话"
                                : "点击开始");
                break;
        }
    }

    private static boolean isPasswordField(EditorInfo editorInfo) {
        if (editorInfo == null) {
            return false;
        }
        int inputClass = editorInfo.inputType & InputType.TYPE_MASK_CLASS;
        int variation = editorInfo.inputType & InputType.TYPE_MASK_VARIATION;
        if (inputClass == InputType.TYPE_CLASS_NUMBER) {
            return variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD;
        }
        if (inputClass != InputType.TYPE_CLASS_TEXT) {
            return false;
        }
        return variation == InputType.TYPE_TEXT_VARIATION_PASSWORD
                || variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
                || variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD;
    }

    private LinearLayout horizontalRow() {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        return row;
    }

    private Button smallButton(String text) {
        Button button = new Button(this);
        button.setText(text);
        button.setAllCaps(false);
        button.setMinHeight(dp(46));
        button.setPadding(dp(5), 0, dp(5), 0);
        return button;
    }

    private LinearLayout.LayoutParams matchWidth() {
        return new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
    }

    private LinearLayout.LayoutParams weighted(float weight) {
        return new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, weight);
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
