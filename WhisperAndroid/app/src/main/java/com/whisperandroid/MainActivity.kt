package com.whisperandroid

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
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
    val ui by viewModel.uiState.collectAsState()
    val context = LocalContext.current
    val languageOptions = remember { viewModel.getLanguageOptions() }

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
            Toast.makeText(context, "Microphone permission denied", Toast.LENGTH_SHORT).show()
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
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Text(
            text = "WhisperAndroid",
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.SemiBold
        )

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ModeButton("STT", ui.mode == AppMode.STT) { viewModel.setMode(AppMode.STT) }
            ModeButton("TTS", ui.mode == AppMode.TTS) { viewModel.setMode(AppMode.TTS) }
            ModeButton("Benchmark", ui.mode == AppMode.BENCHMARK) { viewModel.setMode(AppMode.BENCHMARK) }
        }

        StatusCard(ui = ui, onInitModel = { viewModel.initializeSelectedModel() })

        when (ui.mode) {
            AppMode.STT -> {
                SttPanel(
                    ui = ui,
                    languageOptions = languageOptions,
                    hasMicPermission = hasMicPermission,
                    onRequestMic = { permissionLauncher.launch(Manifest.permission.RECORD_AUDIO) },
                    onSetEngine = viewModel::setSttEngine,
                    onSetMode = viewModel::setSttMode,
                    onSetLanguage = viewModel::setLanguage,
                    onSetDetectLanguage = viewModel::setDetectLanguage,
                    onSetSherpaModel = viewModel::setSherpaModel,
                    onSetNexaModel = viewModel::setNexaModel,
                    onSetRunAnywhereModel = viewModel::setRunAnywhereModel,
                    onNexaChunkChange = viewModel::setNexaChunkSeconds,
                    onNexaOverlapChange = viewModel::setNexaOverlapSeconds,
                    onRaChunkChange = viewModel::setRunAnywhereChunkSeconds,
                    onRaOverlapChange = viewModel::setRunAnywhereOverlapSeconds,
                    onStartClip = viewModel::startClip,
                    onStopClip = viewModel::stopClipAndTranscribe,
                    onStartStreaming = viewModel::startStreaming,
                    onStopStreaming = viewModel::stopStreaming
                )
            }

            AppMode.TTS -> {
                TtsPanel(
                    ui = ui,
                    onUpdateText = viewModel::updateTtsText,
                    onSpeak = viewModel::startSpeaking,
                    onStop = viewModel::stopSpeaking
                )
            }

            AppMode.BENCHMARK -> {
                BenchmarkPanel(
                    ui = ui,
                    onSetClip = viewModel::setBenchmarkClip,
                    onToggleIncludeSherpa = viewModel::toggleBenchmarkIncludeSherpa,
                    onToggleIncludeNexa = viewModel::toggleBenchmarkIncludeNexa,
                    onToggleIncludeRunAnywhere = viewModel::toggleBenchmarkIncludeRunAnywhere,
                    onToggleNexaModel = viewModel::toggleBenchmarkNexaModel,
                    onToggleRunAnywhereModel = viewModel::toggleBenchmarkRunAnywhereModel,
                    onRun = viewModel::runBenchmark
                )
            }
        }

        Spacer(modifier = Modifier.height(16.dp))
    }
}

@Composable
private fun StatusCard(ui: AppUiState, onInitModel: () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
        )
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Text("Status: ${ui.status}")
            Text("Engine: ${ui.sttEngine.displayName}")
            Text("Model Init: ${ui.modelInitMessage}")

            if (ui.modelInitState == ModelInitState.INITIALIZING) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                    Text("Initializing model...")
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onInitModel) {
                    Text("Init/Reload Model")
                }
                if (ui.isProcessing) {
                    Text("Processing...", modifier = Modifier.align(Alignment.CenterVertically))
                }
            }
        }
    }
}

@Composable
private fun SttPanel(
    ui: AppUiState,
    languageOptions: List<String>,
    hasMicPermission: Boolean,
    onRequestMic: () -> Unit,
    onSetEngine: (SttEngineType) -> Unit,
    onSetMode: (SttMode) -> Unit,
    onSetLanguage: (String) -> Unit,
    onSetDetectLanguage: (Boolean) -> Unit,
    onSetSherpaModel: (String) -> Unit,
    onSetNexaModel: (String) -> Unit,
    onSetRunAnywhereModel: (String) -> Unit,
    onNexaChunkChange: (Float) -> Unit,
    onNexaOverlapChange: (Float) -> Unit,
    onRaChunkChange: (Float) -> Unit,
    onRaOverlapChange: (Float) -> Unit,
    onStartClip: () -> Unit,
    onStopClip: () -> Unit,
    onStartStreaming: () -> Unit,
    onStopStreaming: () -> Unit
) {
    Text("STT Engine", fontWeight = FontWeight.Medium)
    SelectableRow(items = SttEngineType.entries.map { it.displayName }, selected = ui.sttEngine.displayName) { label ->
        SttEngineType.entries.firstOrNull { it.displayName == label }?.let(onSetEngine)
    }

    val engineModels = when (ui.sttEngine) {
        SttEngineType.WHISPER -> SherpaOnnxModelCatalog.models
        SttEngineType.NEXA -> NexaModelCatalog.models
        SttEngineType.RUN_ANYWHERE -> RunAnywhereModelCatalog.models
    }
    val selectedModelId = when (ui.sttEngine) {
        SttEngineType.WHISPER -> ui.sherpaModelId
        SttEngineType.NEXA -> ui.nexaModelId
        SttEngineType.RUN_ANYWHERE -> ui.runAnywhereModelId
    }

    Text("Model", fontWeight = FontWeight.Medium)
    SelectableRow(
        items = engineModels.map { it.displayName },
        selected = engineModels.firstOrNull { it.id == selectedModelId }?.displayName
    ) { label ->
        val model = engineModels.firstOrNull { it.displayName == label } ?: return@SelectableRow
        when (ui.sttEngine) {
            SttEngineType.WHISPER -> onSetSherpaModel(model.id)
            SttEngineType.NEXA -> onSetNexaModel(model.id)
            SttEngineType.RUN_ANYWHERE -> onSetRunAnywhereModel(model.id)
        }
    }

    Text("Mode", fontWeight = FontWeight.Medium)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        ModeButton("Clip", ui.sttMode == SttMode.CLIP) { onSetMode(SttMode.CLIP) }
        ModeButton("Streaming", ui.sttMode == SttMode.STREAMING) { onSetMode(SttMode.STREAMING) }
    }

    Text("Language", fontWeight = FontWeight.Medium)
    SelectableRow(items = languageOptions, selected = ui.language) { onSetLanguage(it) }

    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        ModeButton("Detect ON", ui.detectLanguage) { onSetDetectLanguage(true) }
        ModeButton("Detect OFF", !ui.detectLanguage) { onSetDetectLanguage(false) }
    }

    when (ui.sttEngine) {
        SttEngineType.NEXA -> {
            ChunkControl(
                label = "Nexa Chunk (s)",
                value = ui.nexaChunkSeconds,
                onChange = onNexaChunkChange
            )
            ChunkControl(
                label = "Nexa Overlap (s)",
                value = ui.nexaOverlapSeconds,
                onChange = onNexaOverlapChange
            )
        }

        SttEngineType.RUN_ANYWHERE -> {
            ChunkControl(
                label = "RunAnywhere Chunk (s)",
                value = ui.runAnywhereChunkSeconds,
                onChange = onRaChunkChange
            )
            ChunkControl(
                label = "RunAnywhere Overlap (s)",
                value = ui.runAnywhereOverlapSeconds,
                onChange = onRaOverlapChange
            )
        }

        SttEngineType.WHISPER -> {
            Text("Sherpa-ONNX streaming uses fixed chunk 4.0s / overlap 1.0s")
        }
    }

    if (!hasMicPermission) {
        Button(onClick = onRequestMic) {
            Text("Grant microphone permission")
        }
    } else {
        val buttonLabel = when {
            !ui.isListening && ui.sttMode == SttMode.CLIP -> "Start Clip"
            ui.isListening && ui.sttMode == SttMode.CLIP -> "Stop Clip + Transcribe"
            !ui.isListening && ui.sttMode == SttMode.STREAMING -> "Start Streaming"
            else -> "Stop Streaming"
        }

        Button(onClick = {
            when (ui.sttMode) {
                SttMode.CLIP -> if (ui.isListening) onStopClip() else onStartClip()
                SttMode.STREAMING -> if (ui.isListening) onStopStreaming() else onStartStreaming()
            }
        }) {
            Text(buttonLabel)
        }
    }

    Card(
        modifier = Modifier
            .fillMaxWidth()
            .height(220.dp),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.4f))
    ) {
        val transcriptionScroll = rememberScrollState()
        LaunchedEffect(ui.transcription) {
            transcriptionScroll.animateScrollTo(transcriptionScroll.maxValue)
        }
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(10.dp)
                .verticalScroll(transcriptionScroll)
        ) {
            Text(if (ui.transcription.isBlank()) "(No transcription yet)" else ui.transcription)
        }
    }

    PerformanceSection(ui.performance)
}

@Composable
private fun TtsPanel(
    ui: AppUiState,
    onUpdateText: (String) -> Unit,
    onSpeak: () -> Unit,
    onStop: () -> Unit
) {
    OutlinedTextField(
        value = ui.ttsText,
        onValueChange = onUpdateText,
        modifier = Modifier.fillMaxWidth(),
        label = { Text("Text to speak") }
    )

    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(onClick = onSpeak) {
            Text(if (ui.isSpeaking) "Speaking..." else "Speak")
        }
        OutlinedButton(onClick = onStop) {
            Text("Stop")
        }
    }

    Text(if (ui.ttsReady) "TTS ready" else "TTS initializing...")
}

@Composable
private fun BenchmarkPanel(
    ui: AppUiState,
    onSetClip: (String) -> Unit,
    onToggleIncludeSherpa: () -> Unit,
    onToggleIncludeNexa: () -> Unit,
    onToggleIncludeRunAnywhere: () -> Unit,
    onToggleNexaModel: (String) -> Unit,
    onToggleRunAnywhereModel: (String) -> Unit,
    onRun: () -> Unit
) {
    Text("Benchmark Clip", fontWeight = FontWeight.Medium)
    SelectableRow(
        items = BenchmarkClipCatalog.clips.map { it.displayName },
        selected = BenchmarkClipCatalog.clips.firstOrNull { it.id == ui.benchmarkClipId }?.displayName
    ) { selectedLabel ->
        BenchmarkClipCatalog.clips.firstOrNull { it.displayName == selectedLabel }?.let {
            onSetClip(it.id)
        }
    }

    HorizontalDivider()

    Text("Include Engines", fontWeight = FontWeight.Medium)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        ModeButton("Sherpa-ONNX", ui.benchmarkIncludeSherpa, onToggleIncludeSherpa)
        ModeButton("Nexa", ui.benchmarkIncludeNexa, onToggleIncludeNexa)
        ModeButton("RunAnywhere", ui.benchmarkIncludeRunAnywhere, onToggleIncludeRunAnywhere)
    }

    if (ui.benchmarkIncludeNexa) {
        Text("Nexa Models", fontWeight = FontWeight.Medium)
        SelectableRow(
            items = NexaModelCatalog.models.map { it.displayName },
            selectedSet = ui.benchmarkNexaModelIds.mapNotNull { id ->
                NexaModelCatalog.models.find { it.id == id }?.displayName
            }.toSet()
        ) { label ->
            NexaModelCatalog.models.firstOrNull { it.displayName == label }?.let {
                onToggleNexaModel(it.id)
            }
        }
    }

    if (ui.benchmarkIncludeRunAnywhere) {
        Text("RunAnywhere Models", fontWeight = FontWeight.Medium)
        SelectableRow(
            items = RunAnywhereModelCatalog.models.map { it.displayName },
            selectedSet = ui.benchmarkRunAnywhereModelIds.mapNotNull { id ->
                RunAnywhereModelCatalog.models.find { it.id == id }?.displayName
            }.toSet()
        ) { label ->
            RunAnywhereModelCatalog.models.firstOrNull { it.displayName == label }?.let {
                onToggleRunAnywhereModel(it.id)
            }
        }
    }

    Button(
        onClick = onRun,
        enabled = !ui.benchmarkRunning
    ) {
        if (ui.benchmarkRunning) {
            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
            Spacer(modifier = Modifier.size(8.dp))
        }
        Text(if (ui.benchmarkRunning) "Running..." else "Run Benchmark")
    }

    Text("Benchmark Status: ${ui.benchmarkStatus}")

    if (ui.benchmarkReferenceText.isNotBlank()) {
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
            )
        ) {
            Column(modifier = Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Reference Transcript", fontWeight = FontWeight.Medium)
                Text(ui.benchmarkReferenceText)
            }
        }
    }

    if (ui.benchmarkResults.isNotEmpty()) {
        Text("Results", fontWeight = FontWeight.SemiBold)
        ui.benchmarkResults.forEach { result ->
            BenchmarkResultCard(result)
        }
    }
}

@Composable
private fun BenchmarkResultCard(result: BenchmarkResult) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.4f))
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(10.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Text("${result.engine} - ${result.model}", fontWeight = FontWeight.SemiBold)
            if (result.error != null) {
                Text("Error: ${result.error}", color = MaterialTheme.colorScheme.error)
            } else {
                Text("Latency: ${result.latencyMs ?: 0} ms")
                Text(
                    "RTF: ${result.realTimeFactor?.let { "%.2f".format(it) } ?: "-"} | " +
                        "WER: ${result.wer?.let { "%.2f".format(it) } ?: "-"} | " +
                        "CER: ${result.cer?.let { "%.2f".format(it) } ?: "-"}"
                )
                Text(if (result.text.isBlank()) "(empty)" else result.text)
            }
        }
    }
}

@Composable
private fun PerformanceSection(performance: PerformanceStats) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
        )
    ) {
        Column(
            modifier = Modifier.padding(10.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Text("Performance", fontWeight = FontWeight.Medium)
            Text("Latency: ${performance.lastLatencyMs} ms (avg ${performance.avgLatencyMs} ms)")
            Text("Audio: ${"%.2f".format(performance.lastAudioSec)} s")
            Text(
                "RTF: ${"%.2f".format(performance.lastRtf)} " +
                    "(avg ${"%.2f".format(performance.avgRtf)})"
            )
        }
    }
}

@Composable
private fun ChunkControl(label: String, value: Float, onChange: (Float) -> Unit) {
    var text by remember(value) { mutableStateOf("%.1f".format(value)) }

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(label, fontWeight = FontWeight.Medium)
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            OutlinedButton(onClick = {
                val next = (value - 0.2f).coerceAtLeast(0f)
                onChange(next)
                text = "%.1f".format(next)
            }) {
                Text("-")
            }
            OutlinedTextField(
                value = text,
                onValueChange = {
                    text = it
                    it.toFloatOrNull()?.let(onChange)
                },
                modifier = Modifier.weight(1f),
                singleLine = true
            )
            OutlinedButton(onClick = {
                val next = value + 0.2f
                onChange(next)
                text = "%.1f".format(next)
            }) {
                Text("+")
            }
        }
    }
}

@Composable
private fun SelectableRow(
    items: List<String>,
    selected: String? = null,
    selectedSet: Set<String> = emptySet(),
    onSelected: (String) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        items.forEach { label ->
            val isSelected = selected == label || selectedSet.contains(label)
            ModeButton(label, isSelected) { onSelected(label) }
        }
    }
}

@Composable
private fun ModeButton(label: String, selected: Boolean, onClick: () -> Unit) {
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
        colors = colors,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.primary)
    ) {
        Text(label)
    }
}
