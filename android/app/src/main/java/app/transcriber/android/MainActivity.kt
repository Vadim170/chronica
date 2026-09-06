package app.transcriber.android

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import uniffi.transcriber_core.IntervalRecord
import uniffi.transcriber_core.ModelStatus

/**
 * Single-activity entry point. Hosts the Compose UI, requests the microphone
 * permission, and drives [MainViewModel] for the engine and capture lifecycle.
 */
class MainActivity : ComponentActivity() {

    private val viewModel: MainViewModel by viewModels()

    private val requestMic = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted -> if (granted) viewModel.startRecording() }

    private val projectionManager by lazy {
        getSystemService(MediaProjectionManager::class.java)
    }

    /** Tracks whether system-audio capture is currently active (UI toggle). */
    private var systemAudioActive = false

    // Receives the MediaProjection consent result and forwards it to the VM.
    private val requestProjection = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        val data = result.data
        if (result.resultCode == Activity.RESULT_OK && data != null) {
            viewModel.startSystemAudio(result.resultCode, data)
            systemAudioActive = true
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Notification permission is runtime on Android 13+; the ongoing
        // recording notification is mandatory for the foreground service.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            requestNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        setContent {
            MaterialTheme(colorScheme = DarkColors) {
                val state by viewModel.state.collectAsStateWithLifecycle()
                TranscriberScreen(
                    state = state,
                    coreVersion = viewModel.coreVersion,
                    systemAudioSupported = SystemAudioCapture.SUPPORTED,
                    onToggleRecording = { toggleRecording() },
                    onToggleSystemAudio = { toggleSystemAudio() },
                    onDownloadModel = viewModel::downloadModel,
                )
            }
        }
    }

    // Result is best-effort; capture still works without it being granted, but
    // the OS may drop the notification. We don't gate recording on it.
    private val requestNotifications = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { /* no-op: informational only */ }

    /**
     * Toggles system-audio capture. Starting launches the MediaProjection consent
     * dialog (capture begins in [requestProjection] on approval); stopping ends it.
     */
    private fun toggleSystemAudio() {
        if (!SystemAudioCapture.SUPPORTED) return
        if (systemAudioActive) {
            viewModel.stopSystemAudio()
            systemAudioActive = false
        } else {
            projectionManager?.let { requestProjection.launch(it.createScreenCaptureIntent()) }
        }
    }

    /** Starts recording (requesting mic permission first) or stops it. */
    private fun toggleRecording() {
        if (viewModel.state.value.isRecording) {
            viewModel.stopRecording()
            return
        }
        val granted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) viewModel.startRecording() else requestMic.launch(Manifest.permission.RECORD_AUDIO)
    }
}

/** Dark, high-contrast palette for the minimal recorder UI. */
private val DarkColors = darkColorScheme(
    primary = Color(0xFF7C9CFF),
    background = Color(0xFF101014),
    surface = Color(0xFF1A1A20),
    onBackground = Color(0xFFE6E6EA),
    onSurface = Color(0xFFE6E6EA),
)

/**
 * The whole screen: status header, start/stop control, recent-transcript feed,
 * and a model list with per-model download status.
 */
@Composable
fun TranscriberScreen(
    state: EngineState,
    coreVersion: String,
    systemAudioSupported: Boolean,
    onToggleRecording: () -> Unit,
    onToggleSystemAudio: () -> Unit,
    onDownloadModel: (String) -> Unit,
) {
    Scaffold { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            StatusHeader(state, coreVersion)

            Button(
                onClick = onToggleRecording,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(if (state.isRecording) "Stop" else "Start")
            }

            if (systemAudioSupported) {
                OutlinedButton(
                    onClick = onToggleSystemAudio,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("System audio (media only)")
                }
                Text(
                    "Captures media/screen audio from apps that allow it. " +
                        "Calls and DRM-protected audio are blocked by Android.",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
                )
            }

            state.lastError?.let {
                Text(
                    text = it,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                )
            }

            Text("Transcript", style = MaterialTheme.typography.titleMedium)
            TranscriptFeed(state.transcript, modifier = Modifier.weight(1f))

            Text("Models", style = MaterialTheme.typography.titleMedium)
            ModelList(state.models, onDownloadModel)
        }
    }
}

@Composable
private fun StatusHeader(state: EngineState, coreVersion: String) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                text = state.session.name,
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
            )
            val rtf = state.realtimeFactor
            Text(
                text = "Words: ${state.totalWords}" +
                    (rtf?.let { "   RTF: ${"%.2f".format(it)}" } ?: ""),
                style = MaterialTheme.typography.bodyMedium,
            )
            Text(
                text = "core $coreVersion",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
            )
        }
    }
}

@Composable
private fun TranscriptFeed(items: List<IntervalRecord>, modifier: Modifier = Modifier) {
    if (items.isEmpty()) {
        Text(
            "No transcript yet. Press Start and speak.",
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
            modifier = modifier,
        )
        return
    }
    LazyColumn(modifier = modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        items(items, key = { it.id }) { record ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp)) {
                    val text = record.channels.joinToString(" ") { it.text }.ifBlank { "(silence)" }
                    Text(text, fontFamily = FontFamily.SansSerif)
                    Text(
                        "${record.startAt}  •  ${"%.0f".format(record.durationS)}s",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
                    )
                }
            }
        }
    }
}

@Composable
private fun ModelList(models: List<ModelStatus>, onDownload: (String) -> Unit) {
    if (models.isEmpty()) {
        Text(
            "No models reported.",
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
        )
        return
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        models.forEach { m ->
            Card(Modifier.fillMaxWidth()) {
                Row(
                    Modifier.fillMaxWidth().padding(12.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(m.label, fontWeight = FontWeight.Medium)
                        val status = when {
                            m.installed -> "installed"
                            m.downloading -> "downloading ${"%.0f".format(m.progressPct)}%"
                            m.lastError.isNotBlank() -> "error: ${m.lastError}"
                            else -> "not installed"
                        }
                        Text(
                            "${m.family} • $status",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                        )
                    }
                    if (!m.installed && !m.downloading) {
                        Spacer(Modifier.height(0.dp))
                        OutlinedButton(onClick = { onDownload(m.id) }) { Text("Download") }
                    }
                }
            }
        }
    }
}
