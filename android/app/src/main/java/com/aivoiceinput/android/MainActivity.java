package com.aivoiceinput.android;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.os.Bundle;
import android.provider.Settings;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.view.inputmethod.InputMethodInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.LinkedHashMap;
import java.util.Map;
import java.nio.file.Files;

public final class MainActivity extends Activity {
    private static final int MICROPHONE_PERMISSION_REQUEST = 1001;
    private static final String DEBUG_TOKEN_PROVISIONING_FILE = "asr-token.provisioning";

    private TextView setupStatus;
    private EditText serverUrlField;
    private EditText tokenField;
    private EditText languageField;
    private EditText hotwordsField;
    private EditText dictionaryField;
    private EditText styleField;
    private Button dictionaryRecordButton;
    private TextView dictionarySyncStatus;
    private final AsrSession dictionaryRecorder = new AsrSession();
    private Map<String, String> displayedDictionary = new LinkedHashMap<>();
    private CheckBox allowInsecureCheck;
    private Spinner modeSpinner;
    private Spinner activationSpinner;
    private boolean secureProfileLoadFailed;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        importDebugProvisionedToken();
        setTitle("AI语音输入法");
        setContentView(buildContentView());
        loadSettings();
    }

    @Override
    protected void onResume() {
        super.onResume();
        updateSetupStatus();
        syncDictionary();
    }

    @Override
    protected void onDestroy() {
        dictionaryRecorder.cancel();
        super.onDestroy();
    }

    @Override
    public void onRequestPermissionsResult(
            int requestCode,
            String[] permissions,
            int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == MICROPHONE_PERMISSION_REQUEST) {
            updateSetupStatus();
        }
    }

    private View buildContentView() {
        ScrollView scrollView = new ScrollView(this);
        scrollView.setFillViewport(true);
        scrollView.setClipToPadding(false);
        scrollView.setOnApplyWindowInsetsListener((view, insets) -> {
            view.setPadding(0, insets.getSystemWindowInsetTop(), 0, insets.getSystemWindowInsetBottom());
            return insets;
        });
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(dp(20), dp(20), dp(20), dp(28));
        scrollView.addView(content, new ScrollView.LayoutParams(
                ScrollView.LayoutParams.MATCH_PARENT,
                ScrollView.LayoutParams.WRAP_CONTENT));

        TextView title = new TextView(this);
        title.setText("AI语音输入法 · Android 测试版");
        title.setTextSize(24);
        title.setTextColor(Color.rgb(23, 32, 51));
        title.setGravity(Gravity.START);
        content.addView(title, matchWidth());

        TextView introduction = new TextView(this);
        introduction.setText(
                "键盘内直接录音，经私网 ASR 识别；智能整理把最终文字和用户热词交给 AI，指令模式只提交最终文字，原始音频不外发。\n\n"
                        + "首次使用依次完成：允许麦克风 → 启用输入法 → 切换到 AI语音输入。");
        introduction.setTextSize(15);
        introduction.setTextColor(Color.DKGRAY);
        introduction.setPadding(0, dp(10), 0, dp(12));
        content.addView(introduction, matchWidth());

        setupStatus = new TextView(this);
        setupStatus.setTextSize(15);
        setupStatus.setPadding(dp(12), dp(10), dp(12), dp(10));
        setupStatus.setBackgroundColor(Color.rgb(236, 240, 250));
        content.addView(setupStatus, matchWidth());

        LinearLayout setupButtons = horizontalRow();
        Button microphoneButton = button("允许麦克风");
        microphoneButton.setOnClickListener(view -> requestMicrophonePermission());
        setupButtons.addView(microphoneButton, weighted());
        Button enableButton = button("启用输入法");
        enableButton.setOnClickListener(view -> startActivity(
                new Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)));
        setupButtons.addView(enableButton, weighted());
        Button switchButton = button("切换输入法");
        switchButton.setOnClickListener(view -> showInputMethodPicker());
        setupButtons.addView(switchButton, weighted());
        content.addView(setupButtons, matchWidth());

        serverUrlField = addTextField(
                content,
                "ASR WebSocket 地址",
                "wss://… 或 Tailscale ws://…",
                false,
                1);
        tokenField = addTextField(
                content,
                "ASR Bearer Token（使用 Android Keystore 加密）",
                "不会写入源码、日志或明文设置",
                false,
                1);
        tokenField.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        languageField = addTextField(content, "识别语言", "zh-CN", false, 1);

        allowInsecureCheck = new CheckBox(this);
        allowInsecureCheck.setText("允许 localhost/Tailscale 私网使用 ws:// 明文传输");
        allowInsecureCheck.setTextSize(14);
        content.addView(allowInsecureCheck, matchWidth());

        modeSpinner = addSpinner(
                content,
                "默认模式",
                Arrays.asList("忠实听写", "智能整理", "指令模式"));
        activationSpinner = addSpinner(
                content,
                "麦克风按钮操作",
                Arrays.asList("按住说话", "按一下开始，再按一下结束"));

        hotwordsField = addTextField(
                content,
                "热词（每行一个）",
                "例如：Codex",
                true,
                3);
        TextView hotwordsNote = new TextView(this);
        hotwordsNote.setText("热词发送给私网 ASR；智能整理时也会发给文字整理服务。不要填写敏感词。上游是否利用热词取决于 ASR 实现。");
        hotwordsNote.setTextSize(13);
        hotwordsNote.setTextColor(Color.GRAY);
        content.addView(hotwordsNote, matchWidth());
        dictionaryField = addTextField(
                content,
                "个人词典（每行 口述=写法）",
                "例如：扣得克斯=Codex",
                true,
                3);
        dictionaryRecordButton = button("🎙 录音填入读音");
        dictionaryRecordButton.setOnClickListener(view -> toggleDictionaryRecording());
        content.addView(dictionaryRecordButton, matchWidth());
        TextView dictionaryHelp = new TextView(this);
        dictionaryHelp.setText("点录音说出一个词，再点停止。忠实听写会把原始识别结果填到等号左边；等号右边的写法由你填写。");
        dictionaryHelp.setTextSize(13);
        dictionaryHelp.setTextColor(Color.GRAY);
        content.addView(dictionaryHelp, matchWidth());
        dictionarySyncStatus = new TextView(this);
        dictionarySyncStatus.setText("词典将在应用打开时自动同步");
        dictionarySyncStatus.setTextSize(13);
        content.addView(dictionarySyncStatus, matchWidth());
        styleField = addTextField(
                content,
                "表达风格",
                "例如：技术说明，简洁",
                true,
                3);

        Button saveButton = button("保存设置");
        saveButton.setTextSize(17);
        saveButton.setOnClickListener(view -> saveSettings());
        LinearLayout.LayoutParams saveParameters = matchWidth();
        saveParameters.topMargin = dp(16);
        content.addView(saveButton, saveParameters);

        Button resetProfileButton = button("清除并重置加密的热词/词典/风格");
        resetProfileButton.setOnClickListener(view -> confirmResetPrivateProfile());
        content.addView(resetProfileButton, matchWidth());

        TextView privacy = new TextView(this);
        privacy.setText(
                "隐私：不保存录音或转写历史；输入法不会在密码输入框启动录音。当前服务地址为私网入口，手机需连接获准的 Tailscale 网络。");
        privacy.setTextSize(13);
        privacy.setTextColor(Color.GRAY);
        privacy.setPadding(0, dp(16), 0, 0);
        content.addView(privacy, matchWidth());
        return scrollView;
    }

    private void loadSettings() {
        AppSettings settings;
        try {
            settings = AppSettings.load(this);
            secureProfileLoadFailed = false;
        } catch (Exception error) {
            settings = AppSettings.defaults();
            secureProfileLoadFailed = true;
            Toast.makeText(
                    this,
                    error.getMessage() == null ? "无法读取加密的个人资料" : error.getMessage(),
                    Toast.LENGTH_LONG).show();
        }
        serverUrlField.setText(settings.serverUrl);
        languageField.setText(settings.language);
        allowInsecureCheck.setChecked(settings.allowInsecurePrivateNetwork);
        modeSpinner.setSelection(settings.mode.ordinal());
        activationSpinner.setSelection(settings.activationMode.ordinal());
        hotwordsField.setText(String.join("\n", settings.hotwords));
        dictionaryField.setText(AppSettings.serializeDictionary(settings.dictionary));
        displayedDictionary = new LinkedHashMap<>(settings.dictionary);
        styleField.setText(settings.style);
        try {
            tokenField.setText(new SecureTokenStore(this).load());
        } catch (Exception error) {
            tokenField.setText("");
            Toast.makeText(this, error.getMessage(), Toast.LENGTH_LONG).show();
        }
    }

    private void importDebugProvisionedToken() {
        if (!BuildConfig.DEBUG) {
            return;
        }
        java.io.File provisioningFile = getFileStreamPath(DEBUG_TOKEN_PROVISIONING_FILE);
        if (!provisioningFile.isFile()) {
            return;
        }
        byte[] bytes = null;
        try {
            long length = provisioningFile.length();
            if (length <= 0 || length > 4_096) {
                throw new IllegalStateException("调试 Token 导入文件大小无效");
            }
            bytes = Files.readAllBytes(provisioningFile.toPath());
            String token = new String(bytes, java.nio.charset.StandardCharsets.UTF_8).trim();
            if (token.isEmpty()) {
                throw new IllegalStateException("调试 Token 导入文件为空");
            }
            new SecureTokenStore(this).save(token);
            Toast.makeText(this, "项目 Token 已安全写入 Android Keystore", Toast.LENGTH_LONG).show();
        } catch (Exception error) {
            Toast.makeText(this, "项目 Token 安全导入失败", Toast.LENGTH_LONG).show();
        } finally {
            if (bytes != null) {
                Arrays.fill(bytes, (byte) 0);
            }
            try {
                Files.deleteIfExists(provisioningFile.toPath());
            } catch (Exception ignored) {
                // Never keep retrying a plaintext provisioning file automatically.
            }
        }
    }

    private void saveSettings() {
        if (secureProfileLoadFailed) {
            Toast.makeText(
                    this,
                    "加密资料无法读取，已禁止覆盖；请先使用下方按钮明确重置",
                    Toast.LENGTH_LONG).show();
            return;
        }
        String serverUrl = serverUrlField.getText().toString().trim();
        String language = languageField.getText().toString().trim();
        if (language.isEmpty()) {
            language = "zh-CN";
        }
        try {
            ServerUrlValidator.validate(serverUrl, allowInsecureCheck.isChecked());
            Map<String, String> edited = AppSettings.parseDictionary(dictionaryField.getText().toString());
            Map<String, String> latest = AppSettings.load(this).dictionary;
            Map<String, String> combined = DictionaryMerge.merge(
                    displayedDictionary, edited, latest).entries;
            AppSettings settings = new AppSettings(
                    serverUrl,
                    language,
                    InputMode.values()[modeSpinner.getSelectedItemPosition()],
                    AppSettings.ActivationMode.values()[activationSpinner.getSelectedItemPosition()],
                    allowInsecureCheck.isChecked(),
                    AppSettings.parseLines(hotwordsField.getText().toString()),
                    combined,
                    styleField.getText().toString().trim());
            settings.save(this);
            dictionaryField.setText(AppSettings.serializeDictionary(combined));
            displayedDictionary = new LinkedHashMap<>(combined);
            new SecureTokenStore(this).save(tokenField.getText().toString());
            String message = tokenField.getText().toString().trim().isEmpty()
                    ? "设置已保存；使用前还需要填写 ASR Token"
                    : "设置已保存，可切换到 AI语音输入开始测试";
            Toast.makeText(this, message, Toast.LENGTH_LONG).show();
            updateSetupStatus();
            syncDictionary();
        } catch (Exception error) {
            Toast.makeText(
                    this,
                    error.getMessage() == null ? "保存设置失败" : error.getMessage(),
                    Toast.LENGTH_LONG).show();
        }
    }

    private void syncDictionary() {
        DictionarySyncClient.schedule(this, (status, dictionaryText) -> {
            if (isFinishing() || isDestroyed()) return;
            dictionarySyncStatus.setText(status);
            if (dictionaryText != null
                    && AppSettings.parseDictionary(dictionaryField.getText().toString())
                        .equals(displayedDictionary)) {
                dictionaryField.setText(dictionaryText);
                displayedDictionary = AppSettings.parseDictionary(dictionaryText);
            }
        });
    }

    private void toggleDictionaryRecording() {
        if (dictionaryRecorder.isActive()) {
            dictionaryRecorder.finish();
            return;
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestMicrophonePermission();
            return;
        }
        try {
            AppSettings configuration = new AppSettings(
                    serverUrlField.getText().toString().trim(),
                    languageField.getText().toString().trim().isEmpty()
                            ? "zh-CN" : languageField.getText().toString().trim(),
                    InputMode.FAITHFUL, AppSettings.ActivationMode.TOGGLE,
                    allowInsecureCheck.isChecked(),
                    java.util.Collections.emptyList(), java.util.Collections.emptyMap(), "");
            dictionaryRecorder.start(this, configuration,
                    tokenField.getText().toString(), getPackageName(), new AsrSession.Callback() {
                        @Override
                        public void onStateChanged(AsrSession.State state, String message) {
                            dictionaryRecordButton.setText(
                                    state == AsrSession.State.RECORDING
                                            || state == AsrSession.State.CONNECTING
                                            ? "■ 停止并识别" : "🎙 录音填入读音");
                            dictionaryRecordButton.setEnabled(state != AsrSession.State.FINALIZING);
                            dictionarySyncStatus.setText(message);
                        }

                        @Override
                        public void onPartial(String text) {
                            dictionarySyncStatus.setText("实时识别：" + text);
                        }

                        @Override
                        public void onFinal(String text) {
                            String spoken = text.trim()
                                    .replaceAll("^[，。！？；,.!?;\\s]+|[，。！？；,.!?;\\s]+$", "");
                            if (spoken.isEmpty() || spoken.codePointCount(0, spoken.length()) > 100
                                    || spoken.contains("=") || spoken.contains("\n")) {
                                dictionarySyncStatus.setText("读音无效，请重新录入");
                                return;
                            }
                            String previous = dictionaryField.getText().toString().trim();
                            String next = previous.isEmpty() ? spoken + "=" : previous + "\n" + spoken + "=";
                            dictionaryField.setText(next);
                            dictionaryField.setSelection(next.length());
                            dictionarySyncStatus.setText("已填入读音，请在等号后填写写法并保存");
                        }

                        @Override
                        public void onError(String message) {
                            dictionaryRecordButton.setText("🎙 录音填入读音");
                            dictionaryRecordButton.setEnabled(true);
                            dictionarySyncStatus.setText(message);
                        }
                    });
        } catch (Exception error) {
            dictionarySyncStatus.setText("无法开始词典录音，请检查服务设置");
        }
    }

    private void requestMicrophonePermission() {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            Toast.makeText(this, "麦克风权限已经允许", Toast.LENGTH_SHORT).show();
            return;
        }
        requestPermissions(
                new String[]{Manifest.permission.RECORD_AUDIO},
                MICROPHONE_PERMISSION_REQUEST);
    }

    private void confirmResetPrivateProfile() {
        new AlertDialog.Builder(this)
                .setTitle("清除个人资料？")
                .setMessage("这会删除热词、个人词典和表达风格，并重建其加密密钥；服务器地址和 Token 不受影响。")
                .setNegativeButton("取消", null)
                .setPositiveButton("确认清除", (dialog, which) -> {
                    try {
                        new SecureProfileStore(this).reset();
                        hotwordsField.setText("");
                        dictionaryField.setText("");
                        styleField.setText("");
                        secureProfileLoadFailed = false;
                        Toast.makeText(this, "个人资料已清除", Toast.LENGTH_LONG).show();
                    } catch (Exception error) {
                        Toast.makeText(
                                this,
                                error.getMessage() == null ? "无法重置个人资料" : error.getMessage(),
                                Toast.LENGTH_LONG).show();
                    }
                })
                .show();
    }

    private void showInputMethodPicker() {
        InputMethodManager manager =
                (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
        manager.showInputMethodPicker();
    }

    private void updateSetupStatus() {
        if (setupStatus == null) {
            return;
        }
        boolean microphoneAllowed = checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                == PackageManager.PERMISSION_GRANTED;
        boolean inputMethodEnabled = isInputMethodEnabled();
        setupStatus.setText(
                (microphoneAllowed ? "✓" : "○") + " 麦克风权限    "
                        + (inputMethodEnabled ? "✓" : "○") + " 输入法已启用");
        setupStatus.setTextColor(
                microphoneAllowed && inputMethodEnabled
                        ? Color.rgb(25, 110, 65)
                        : Color.rgb(115, 70, 20));
    }

    private boolean isInputMethodEnabled() {
        InputMethodManager manager =
                (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
        for (InputMethodInfo info : manager.getEnabledInputMethodList()) {
            if (getPackageName().equals(info.getPackageName())) {
                return true;
            }
        }
        return false;
    }

    private EditText addTextField(
            LinearLayout parent,
            String label,
            String hint,
            boolean multiline,
            int lines) {
        addLabel(parent, label);
        EditText field = new EditText(this);
        field.setHint(hint);
        field.setTextSize(15);
        field.setSingleLine(!multiline);
        field.setMinLines(lines);
        field.setMaxLines(lines);
        field.setGravity(multiline ? Gravity.TOP | Gravity.START : Gravity.CENTER_VERTICAL);
        field.setInputType(multiline
                ? InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE
                : InputType.TYPE_CLASS_TEXT);
        parent.addView(field, matchWidth());
        return field;
    }

    private Spinner addSpinner(LinearLayout parent, String label, List<String> choices) {
        addLabel(parent, label);
        Spinner spinner = new Spinner(this);
        ArrayAdapter<String> adapter = new ArrayAdapter<>(
                this,
                android.R.layout.simple_spinner_item,
                new ArrayList<>(choices));
        adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        spinner.setAdapter(adapter);
        parent.addView(spinner, matchWidth());
        return spinner;
    }

    private void addLabel(LinearLayout parent, String text) {
        TextView label = new TextView(this);
        label.setText(text);
        label.setTextSize(14);
        label.setTextColor(Color.rgb(23, 32, 51));
        label.setPadding(0, dp(14), 0, 0);
        parent.addView(label, matchWidth());
    }

    private LinearLayout horizontalRow() {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setPadding(0, dp(10), 0, 0);
        return row;
    }

    private Button button(String text) {
        Button button = new Button(this);
        button.setText(text);
        button.setAllCaps(false);
        button.setMinHeight(dp(48));
        return button;
    }

    private LinearLayout.LayoutParams matchWidth() {
        return new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
    }

    private LinearLayout.LayoutParams weighted() {
        return new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1);
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
