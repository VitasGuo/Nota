package com.vitasguo.nota

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile

class MainActivity : FlutterActivity() {
    private val CHANNEL = "nota/audio_capture"
    private val TAG = "NotaAudioCapture"
    private val REQUEST_CODE_CAPTURE = 1001

    private var mediaProjectionManager: MediaProjectionManager? = null
    private var mediaProjection: MediaProjection? = null
    private var audioRecord: AudioRecord? = null
    private var recordThread: Thread? = null

    @Volatile
    private var isRecording = false
    private var outputFile: String? = null
    private var pendingResult: MethodChannel.Result? = null
    private var dataBytes: Long = 0

    // 16kHz 单声道 PCM_16BIT —— ASR 标准输入
    private val sampleRate = 16000
    private val channelConfig = AudioFormat.CHANNEL_IN_MONO
    private val audioEncoding = AudioFormat.ENCODING_PCM_16BIT
    private val channels = 1
    private val bitsPerSample = 16

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startCapture" -> {
                        val outputPath = call.argument<String>("outputPath")
                        startAudioCapture(outputPath, result)
                    }
                    "stopCapture" -> stopAudioCapture(result)
                    "isCaptureAvailable" -> {
                        result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// 请求 MediaProjection 授权后开始内录
    private fun startAudioCapture(outputPath: String?, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("UNSUPPORTED", "Requires Android 10+ (API 29)", null)
            return
        }
        if (isRecording) {
            result.error("ALREADY_RECORDING", "Already capturing", null)
            return
        }
        if (outputPath.isNullOrEmpty()) {
            result.error("INVALID_PATH", "outputPath is null or empty", null)
            return
        }

        outputFile = outputPath
        pendingResult = result

        mediaProjectionManager =
            getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
        if (mediaProjectionManager == null) {
            pendingResult?.error("NO_SERVICE", "MediaProjectionService unavailable", null)
            pendingResult = null
            outputFile = null
            return
        }

        val captureIntent = mediaProjectionManager!!.createScreenCaptureIntent()
        @Suppress("DEPRECATION")
        startActivityForResult(captureIntent, REQUEST_CODE_CAPTURE)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_CODE_CAPTURE) return

        if (resultCode != RESULT_OK || data == null) {
            // 用户拒绝授权
            pendingResult?.success(false)
            pendingResult = null
            outputFile = null
            return
        }

        try {
            val projection = mediaProjectionManager!!.getMediaProjection(resultCode, data!!)
            if (projection == null) {
                throw IllegalStateException("getMediaProjection returned null")
            }
            mediaProjection = projection
            startRecordingWithProjection(projection)
        } catch (e: Exception) {
            Log.e(TAG, "getMediaProjection failed", e)
            pendingResult?.error("PROJECTION_FAILED", e.message, null)
            pendingResult = null
            outputFile = null
        }
    }

    /// 配置 AudioPlaybackCaptureConfiguration + AudioRecord，启动录制线程
    @SuppressLint("NewApi", "MissingPermission")
    private fun startRecordingWithProjection(projection: MediaProjection) {
        val config = AudioPlaybackCaptureConfiguration.Builder(projection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .build()

        val audioFormat = AudioFormat.Builder()
            .setEncoding(audioEncoding)
            .setSampleRate(sampleRate)
            .setChannelMask(channelConfig)
            .build()

        val minBuf = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioEncoding)
        if (minBuf <= 0) {
            pendingResult?.error("BUF_SIZE_INVALID", "getMinBufferSize=$minBuf", null)
            pendingResult = null
            cleanupProjection()
            return
        }
        // 至少容纳 1 秒数据（16kHz * 16bit * mono = 32000 bytes/s）
        val bufferSize = (minBuf * 2).coerceAtLeast(sampleRate * channels * bitsPerSample / 8)

        val recorder = AudioRecord.Builder()
            .setAudioFormat(audioFormat)
            .setBufferSizeInBytes(bufferSize)
            .setAudioPlaybackCaptureConfig(config)
            .build()

        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            pendingResult?.error("INIT_FAILED", "AudioRecord not initialized (state=${recorder.state})", null)
            pendingResult = null
            recorder.release()
            cleanupProjection()
            return
        }

        audioRecord = recorder
        dataBytes = 0

        // 写入 WAV 头占位（数据大小随后回填）
        val path = outputFile!!
        val file = File(path)
        file.parentFile?.mkdirs()
        FileOutputStream(file).use { writeWavHeader(it, 0L) }

        isRecording = true
        recorder.startRecording()

        recordThread = Thread {
            val buffer = ByteArray(minBuf)
            val out = FileOutputStream(file, true) // 追加到 header 之后
            try {
                while (isRecording) {
                    val read = recorder.read(buffer, 0, buffer.size)
                    if (read > 0) {
                        out.write(buffer, 0, read)
                        dataBytes += read
                    } else if (read == AudioRecord.ERROR_INVALID_OPERATION ||
                        read == AudioRecord.ERROR_BAD_VALUE
                    ) {
                        Log.e(TAG, "AudioRecord read error: $read")
                        break
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Recording loop error", e)
            } finally {
                try {
                    out.flush()
                    out.close()
                } catch (e: Exception) {
                    Log.e(TAG, "Close output error", e)
                }
                // 回填 WAV 头中的数据大小
                try {
                    RandomAccessFile(file, "rw").use { updateWavDataSize(it, dataBytes) }
                } catch (e: Exception) {
                    Log.e(TAG, "WAV header backfill error", e)
                }
            }
        }.also { it.start() }

        // 通知 Dart 启动成功
        pendingResult?.success(true)
        pendingResult = null
    }

    /// 停止内录，返回文件路径
    private fun stopAudioCapture(result: MethodChannel.Result) {
        if (!isRecording) {
            result.error("NOT_RECORDING", "Not capturing", null)
            return
        }

        isRecording = false
        // 先 stop 以解除 recorder.read() 阻塞
        try {
            audioRecord?.stop()
        } catch (e: Exception) {
            Log.e(TAG, "AudioRecord.stop error", e)
        }
        try {
            recordThread?.join(3000)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        recordThread = null

        audioRecord?.release()
        audioRecord = null
        cleanupProjection()

        val path = outputFile
        outputFile = null
        result.success(path)
    }

    private fun cleanupProjection() {
        try {
            mediaProjection?.stop()
        } catch (e: Exception) {
            Log.e(TAG, "MediaProjection.stop error", e)
        }
        mediaProjection = null
    }

    /// 标准 PCM WAV 文件头（44 字节）。dataLength 为占位值，停止后回填。
    private fun writeWavHeader(out: FileOutputStream, dataLength: Long) {
        val byteRate = sampleRate * channels * bitsPerSample / 8
        val blockAlign = channels * bitsPerSample / 8

        out.write("RIFF".toByteArray())
        writeInt32LE(out, 36 + dataLength)
        out.write("WAVE".toByteArray())
        out.write("fmt ".toByteArray())
        writeInt32LE(out, 16)
        writeInt16LE(out, 1) // PCM
        writeInt16LE(out, channels)
        writeInt32LE(out, sampleRate.toLong())
        writeInt32LE(out, byteRate.toLong())
        writeInt16LE(out, blockAlign)
        writeInt16LE(out, bitsPerSample)
        out.write("data".toByteArray())
        writeInt32LE(out, dataLength)
    }

    /// 回填 RIFF chunk size（偏移 4）与 data chunk size（偏移 40）
    private fun updateWavDataSize(raf: RandomAccessFile, dataLength: Long) {
        raf.seek(4)
        raf.write(intToLE(36 + dataLength))
        raf.seek(40)
        raf.write(intToLE(dataLength))
    }

    private fun writeInt32LE(out: FileOutputStream, v: Long) {
        out.write(intToLE(v))
    }

    private fun writeInt16LE(out: FileOutputStream, v: Int) {
        out.write(byteArrayOf((v and 0xFF).toByte(), ((v shr 8) and 0xFF).toByte()))
    }

    private fun intToLE(v: Long): ByteArray =
        byteArrayOf(
            (v and 0xFF).toByte(),
            ((v shr 8) and 0xFF).toByte(),
            ((v shr 16) and 0xFF).toByte(),
            ((v shr 24) and 0xFF).toByte(),
        )
}
