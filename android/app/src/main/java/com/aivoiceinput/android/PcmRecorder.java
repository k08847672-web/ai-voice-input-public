package com.aivoiceinput.android;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaRecorder;

import java.util.Arrays;
import java.util.concurrent.atomic.AtomicBoolean;

final class PcmRecorder {
    interface Listener {
        void onAudio(byte[] bytes);
        void onError(String message);
    }

    private static final int SAMPLE_RATE = 16_000;
    private static final int FRAME_BYTES = 3_200;

    private final AtomicBoolean running = new AtomicBoolean(false);
    private AudioRecord audioRecord;
    private Thread recordingThread;

    synchronized void start(Context context, Listener listener) {
        if (running.get()) {
            return;
        }
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED) {
            throw new SecurityException("未获得麦克风权限");
        }
        int minimumBufferSize = AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT);
        if (minimumBufferSize <= 0) {
            throw new IllegalStateException("设备不支持 16 kHz 单声道 PCM 录音");
        }

        AudioFormat format = new AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .build();
        AudioRecord recorder = new AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
                .setAudioFormat(format)
                .setBufferSizeInBytes(Math.max(minimumBufferSize * 2, FRAME_BYTES * 4))
                .build();
        if (recorder.getState() != AudioRecord.STATE_INITIALIZED) {
            recorder.release();
            throw new IllegalStateException("麦克风初始化失败");
        }

        audioRecord = recorder;
        running.set(true);
        try {
            recorder.startRecording();
        } catch (RuntimeException error) {
            running.set(false);
            audioRecord = null;
            recorder.release();
            throw new IllegalStateException("无法开始录音，请检查麦克风权限", error);
        }

        recordingThread = new Thread(
                () -> recordLoop(recorder, listener),
                "voice-input-pcm-recorder");
        recordingThread.start();
    }

    synchronized void stop() {
        running.set(false);
        AudioRecord recorder = audioRecord;
        if (recorder != null) {
            try {
                recorder.stop();
            } catch (IllegalStateException ignored) {
                // The read loop will release the recorder.
            }
        }
        Thread thread = recordingThread;
        if (thread != null) {
            thread.interrupt();
        }
    }

    boolean isRunning() {
        return running.get();
    }

    private void recordLoop(AudioRecord recorder, Listener listener) {
        byte[] buffer = new byte[FRAME_BYTES];
        try {
            while (running.get()) {
                int count = recorder.read(buffer, 0, buffer.length, AudioRecord.READ_BLOCKING);
                if (count > 0) {
                    listener.onAudio(Arrays.copyOf(buffer, count));
                } else if (count != AudioRecord.ERROR_INVALID_OPERATION && running.get()) {
                    listener.onError("麦克风读取失败（" + count + "）");
                    return;
                }
            }
        } catch (RuntimeException error) {
            if (running.get()) {
                listener.onError("麦克风录音中断");
            }
        } finally {
            running.set(false);
            recorder.release();
            synchronized (this) {
                if (audioRecord == recorder) {
                    audioRecord = null;
                    recordingThread = null;
                }
            }
        }
    }
}
