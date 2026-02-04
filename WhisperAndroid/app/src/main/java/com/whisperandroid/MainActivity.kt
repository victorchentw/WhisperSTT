package com.whisperandroid

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import com.whisperandroid.ui.theme.WhisperAndroidTheme
import kotlinx.coroutines.flow.collectLatest

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            WhisperAndroidTheme {
                MainScreen()
            }
        }
    }
}

@Composable
private fun MainScreen(viewModel: MainViewModel = viewModel()) {
    val context = LocalContext.current
    val mode by viewModel.mode.collectAsState()
    val sttMode by viewModel.sttMode.collectAsState()
    val status by viewModel.status.collectAsState()
    val transcription by viewModel.transcription.collectAsState()
    val performance by viewModel.performance.collectAsState()
    val ttsText by viewModel.ttsText.collectAsState()
    val isListening by viewModel.isListening.collectAsState()
    val isSpeaking by viewModel.isSpeaking.collectAsState()
    val ttsReady by viewModel.ttsReady.collectAsState()
    val language by viewModel.language.collectAsState()
    val languageOptions = viewModel.languageOptions

    var hasMicPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.RECORD_AUDIO
            ) == PackageManager.PERMISSION_GRANTED
        )
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        hasMicPermission = granted
        if (!granted) {
            Toast.makeText(context, "Mic permission denied", Toast.LENGTH_SHORT).show()
        }
    }

    LaunchedEffect(Unit) {
        viewModel.toastFlow.collectLatest { message ->
            Toast.makeText(context, message, Toast.LENGTH_SHORT).show()
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp)
    ) {
        Text(
            text = "WhisperAndroid",
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.SemiBold
        )
        Text(text = "Model: Whisper tiny (multilingual)")
        Spacer(modifier = Modifier.height(12.dp))

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ToggleButton(
                label = "STT",
                selected = mode == MainMode.STT
            ) { viewModel.setMode(MainMode.STT) }
            ToggleButton(
                label = "TTS",
                selected = mode == MainMode.TTS
            ) { viewModel.setMode(MainMode.TTS) }
        }

        Spacer(modifier = Modifier.height(16.dp))

        Text(text = "Status: $status")
        Spacer(modifier = Modifier.height(12.dp))

        when (mode) {
            MainMode.STT -> {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    ToggleButton(
                        label = "Streaming",
                        selected = sttMode == SttMode.STREAMING
                    ) { viewModel.setSttMode(SttMode.STREAMING) }
                    ToggleButton(
                        label = "Clip",
                        selected = sttMode == SttMode.CLIP
                    ) { viewModel.setSttMode(SttMode.CLIP) }
                }

                Spacer(modifier = Modifier.height(12.dp))

                Text(text = "Language")
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    for (code in languageOptions) {
                        ToggleButton(
                            label = code.uppercase(),
                            selected = language == code
                        ) { viewModel.setLanguage(code) }
                    }
                }

                Spacer(modifier = Modifier.height(12.dp))

                if (!hasMicPermission) {
                    Button(onClick = { permissionLauncher.launch(Manifest.permission.RECORD_AUDIO) }) {
                        Text("Grant mic permission")
                    }
                } else {
                    val buttonLabel = if (isListening) {
                        if (sttMode == SttMode.STREAMING) "Stop Streaming" else "Stop Clip"
                    } else {
                        if (sttMode == SttMode.STREAMING) "Start Streaming" else "Start Clip"
                    }

                    Button(onClick = {
                        if (!isListening) {
                            if (sttMode == SttMode.STREAMING) {
                                viewModel.startStreaming()
                            } else {
                                viewModel.startClip()
                            }
                        } else {
                            if (sttMode == SttMode.STREAMING) {
                                viewModel.stopStreaming()
                            } else {
                                viewModel.stopClipAndTranscribe()
                            }
                        }
                    }) {
                        Text(buttonLabel)
                    }
                }

                Spacer(modifier = Modifier.height(12.dp))

                TranscriptionBox(transcription = transcription)

                Spacer(modifier = Modifier.height(12.dp))

                PerformanceSection(performance = performance)
            }

            MainMode.TTS -> {
                TextField(
                    value = ttsText,
                    onValueChange = { viewModel.updateTtsText(it) },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("Text to speak") }
                )

                Spacer(modifier = Modifier.height(12.dp))

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { viewModel.startSpeaking() }) {
                        Text(if (isSpeaking) "Speaking..." else "Speak")
                    }
                    OutlinedButton(onClick = { viewModel.stopSpeaking() }) {
                        Text("Stop")
                    }
                }

                Spacer(modifier = Modifier.height(8.dp))
                Text(text = if (ttsReady) "TTS ready" else "TTS initializing...")
            }
        }
    }
}

@Composable
private fun ToggleButton(label: String, selected: Boolean, onClick: () -> Unit) {
    val colors = if (selected) {
        ButtonDefaults.outlinedButtonColors(
            containerColor = MaterialTheme.colorScheme.primary,
            contentColor = MaterialTheme.colorScheme.onPrimary
        )
    } else {
        ButtonDefaults.outlinedButtonColors()
    }

    OutlinedButton(
        onClick = onClick,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.primary),
        colors = colors
    ) {
        Text(label)
    }
}

@Composable
private fun TranscriptionBox(transcription: String) {
    val scrollState = rememberScrollState()

    LaunchedEffect(transcription) {
        scrollState.animateScrollTo(scrollState.maxValue)
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(240.dp)
            .verticalScroll(scrollState)
            .padding(12.dp)
    ) {
        Text(
            text = if (transcription.isBlank()) "(No transcription yet)" else transcription,
            fontSize = 16.sp
        )
    }
}

@Composable
private fun PerformanceSection(performance: PerformanceStats) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        Text("Performance", fontWeight = FontWeight.Medium)
        Text("Latency: ${performance.lastLatencyMs} ms (avg ${performance.avgLatencyMs} ms)")
        Text("Audio: ${"%.2f".format(performance.lastAudioSec)} s")
        Text("RTF: ${"%.2f".format(performance.lastRtf)} (avg ${"%.2f".format(performance.avgRtf)})")
    }
}
