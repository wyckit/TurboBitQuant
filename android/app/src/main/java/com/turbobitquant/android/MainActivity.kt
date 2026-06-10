package com.turbobitquant.android

import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.activity.addCallback
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.arm.aichat.AiChat
import com.arm.aichat.InferenceEngine
import com.arm.aichat.gguf.GgufMetadata
import com.arm.aichat.gguf.GgufMetadataReader
import com.google.android.material.floatingactionbutton.FloatingActionButton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.UUID

class MainActivity : AppCompatActivity() {

    private lateinit var ggufTv: TextView
    private lateinit var hubStatusTv: TextView
    private lateinit var hubSearchInput: EditText
    private lateinit var hubSearchButton: Button
    private lateinit var localModelButton: Button
    private lateinit var reposContainer: LinearLayout
    private lateinit var filesContainer: LinearLayout
    private lateinit var downloadsContainer: LinearLayout
    private lateinit var messagesRv: RecyclerView
    private lateinit var userInputEt: EditText
    private lateinit var userActionFab: FloatingActionButton

    private lateinit var engine: InferenceEngine
    private var generationJob: Job? = null
    private var isModelReady = false

    private val activeDownloads = linkedMapOf<String, DownloadState>()
    private val messages = mutableListOf<Message>()
    private val lastAssistantMsg = StringBuilder()
    private val messageAdapter = MessageAdapter(messages)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContentView(R.layout.activity_main)
        onBackPressedDispatcher.addCallback { Log.w(TAG, "Ignore back press for simplicity") }

        ggufTv = findViewById(R.id.gguf)
        hubStatusTv = findViewById(R.id.hub_status)
        hubSearchInput = findViewById(R.id.hub_search_input)
        hubSearchButton = findViewById(R.id.hub_search_btn)
        localModelButton = findViewById(R.id.local_model_btn)
        reposContainer = findViewById(R.id.hub_repos)
        filesContainer = findViewById(R.id.hub_files)
        downloadsContainer = findViewById(R.id.downloads)
        messagesRv = findViewById(R.id.messages)
        userInputEt = findViewById(R.id.user_input)
        userActionFab = findViewById(R.id.fab)

        messagesRv.layoutManager = LinearLayoutManager(this).apply { stackFromEnd = true }
        messagesRv.adapter = messageAdapter
        localModelButton.isEnabled = false
        hubStatusTv.text = "Initializing on-device inference engine..."

        lifecycleScope.launch(Dispatchers.Default) {
            try {
                engine = AiChat.getInferenceEngine(applicationContext)
                awaitEngineInitialized()
                withContext(Dispatchers.Main) {
                    localModelButton.isEnabled = true
                    hubStatusTv.text = "Search Hugging Face or pick a GGUF file already stored on this phone."
                }
                tryLoadBundledModel()
                withContext(Dispatchers.Main) { renderDownloads() }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to initialize inference engine", e)
                withContext(Dispatchers.Main) {
                    setIdleWithoutModel("Inference engine failed to initialize: ${e.message}")
                    localModelButton.isEnabled = false
                }
            }
        }

        localModelButton.setOnClickListener {
            getContent.launch(arrayOf("*/*"))
        }

        hubSearchButton.setOnClickListener {
            val query = hubSearchInput.text.toString().trim()
            if (query.isEmpty()) {
                Toast.makeText(this, "Enter a model search query.", Toast.LENGTH_SHORT).show()
            } else {
                searchHuggingFace(query)
            }
        }

        userActionFab.setOnClickListener {
            if (isModelReady) {
                handleUserInput()
            }
        }
    }

    private val getContent = registerForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri ->
        Log.i(TAG, "Selected file uri:\n $uri")
        uri?.let { handleSelectedModel(it) }
    }

    private fun handleSelectedModel(uri: Uri) {
        setLoadingState("Parsing selected GGUF...")
        ggufTv.text = "Parsing metadata from selected file\n$uri"

        lifecycleScope.launch(Dispatchers.IO) {
            try {
                val metadata = contentResolver.openInputStream(uri)?.use {
                    GgufMetadataReader.create().readStructuredMetadata(it)
                } ?: error("Could not open selected model.")

                val modelName = metadata.filename() + FILE_EXTENSION_GGUF
                val modelFile = contentResolver.openInputStream(uri)?.use { input ->
                    ensureModelFile(modelName, input)
                } ?: error("Could not copy selected model.")

                loadModel(modelName, modelFile, metadata.toString())
            } catch (e: Exception) {
                Log.e(TAG, "Failed to load selected model", e)
                withContext(Dispatchers.Main) {
                    setIdleWithoutModel("Failed to load selected model: ${e.message}")
                }
            }
        }
    }

    private fun tryLoadBundledModel() {
        lifecycleScope.launch(Dispatchers.IO) {
            val assetName = assets.list(ASSET_DIRECTORY_MODELS)
                ?.firstOrNull { it.endsWith(FILE_EXTENSION_GGUF, ignoreCase = true) }
                ?: return@launch

            try {
                withContext(Dispatchers.Main) {
                    setLoadingState("Loading bundled model...")
                    ggufTv.text = "Loading bundled GGUF model\n$assetName"
                }

                val assetPath = "$ASSET_DIRECTORY_MODELS/$assetName"
                val metadataText = assets.open(assetPath).use { metadataInput ->
                    GgufMetadataReader.create().readStructuredMetadata(metadataInput).toString()
                }
                val modelFile = assets.open(assetPath).use { input ->
                    ensureModelFile(assetName, input)
                }

                loadModel(assetName, modelFile, metadataText)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to load bundled model", e)
                withContext(Dispatchers.Main) {
                    setIdleWithoutModel("Bundled model failed to load: ${e.message}")
                }
            }
        }
    }

    private fun searchHuggingFace(query: String) {
        hubSearchButton.isEnabled = false
        hubStatusTv.text = "Searching Hugging Face..."
        reposContainer.removeAllViews()
        filesContainer.removeAllViews()

        lifecycleScope.launch(Dispatchers.IO) {
            try {
                val url = "$HF_API_MODELS?search=${encodeQuery(query)}&filter=gguf&sort=downloads&direction=-1&limit=15"
                val response = httpGet(url)
                val repos = parseRepos(response)

                withContext(Dispatchers.Main) {
                    hubStatusTv.text = if (repos.isEmpty()) {
                        "No GGUF repositories found. Try a smaller query such as gemma 2b q4."
                    } else {
                        "Found ${repos.size} repositories. Pick one to inspect GGUF files."
                    }
                    renderRepos(repos)
                }
            } catch (e: Exception) {
                Log.e(TAG, "HF search failed", e)
                withContext(Dispatchers.Main) {
                    hubStatusTv.text = "Search failed: ${e.message}"
                }
            } finally {
                withContext(Dispatchers.Main) {
                    hubSearchButton.isEnabled = true
                }
            }
        }
    }

    private fun loadRepoFiles(repo: HubRepo) {
        hubStatusTv.text = "Fetching files for ${repo.id}..."
        filesContainer.removeAllViews()

        lifecycleScope.launch(Dispatchers.IO) {
            try {
                val response = httpGet("$HF_API_MODELS/${repo.id}")
                val files = parseGgufFiles(response)

                withContext(Dispatchers.Main) {
                    hubStatusTv.text = if (files.isEmpty()) {
                        "No GGUF files found in ${repo.id}."
                    } else {
                        "${repo.id}: ${files.size} GGUF files found. Prefer Q4 files under 3GB for phones."
                    }
                    renderFiles(repo, files)
                }
            } catch (e: Exception) {
                Log.e(TAG, "HF file lookup failed", e)
                withContext(Dispatchers.Main) {
                    hubStatusTv.text = "Could not fetch repo files: ${e.message}"
                }
            }
        }
    }

    private fun startModelDownload(repo: HubRepo, remoteFilename: String) {
        val localName = safeBasename(remoteFilename)
        val dest = File(ensureModelsDirectory(), localName)

        if (activeDownloads.containsKey(localName)) {
            Toast.makeText(this, "Download already active for $localName", Toast.LENGTH_SHORT).show()
            return
        }
        if (dest.exists()) {
            Toast.makeText(this, "$localName is already downloaded.", Toast.LENGTH_SHORT).show()
            renderDownloads()
            return
        }

        val state = DownloadState(
            filename = localName,
            repoId = repo.id,
            remoteFilename = remoteFilename,
            file = dest
        )
        activeDownloads[localName] = state
        renderDownloads()

        val job = lifecycleScope.launch(Dispatchers.IO) {
            val partFile = File(dest.parentFile, "$localName.part")
            try {
                state.status = "Connecting"
                updateDownloadUi()

                val url = "https://huggingface.co/${repo.id}/resolve/main/${encodePath(remoteFilename)}"
                val connection = (URL(url).openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = 20_000
                    readTimeout = 30_000
                    setRequestProperty("User-Agent", "TurboBitQuant-Android")
                }

                if (connection.responseCode !in 200..299) {
                    error("HTTP ${connection.responseCode}")
                }

                state.totalBytes = connection.contentLengthLong.takeIf { it > 0L } ?: 0L
                state.status = "Downloading"

                connection.inputStream.use { input ->
                    FileOutputStream(partFile).use { output ->
                        val buffer = ByteArray(DOWNLOAD_BUFFER_SIZE)
                        var lastUiUpdate = 0L

                        while (true) {
                            currentCoroutineContext().ensureActive()
                            val read = input.read(buffer)
                            if (read == -1) break
                            output.write(buffer, 0, read)
                            state.downloadedBytes += read

                            val now = System.currentTimeMillis()
                            if (now - lastUiUpdate >= DOWNLOAD_UI_INTERVAL_MS) {
                                lastUiUpdate = now
                                updateDownloadUi()
                            }
                        }
                    }
                }

                if (dest.exists()) dest.delete()
                if (!partFile.renameTo(dest)) {
                    error("Could not finalize downloaded file.")
                }

                activeDownloads.remove(localName)
                withContext(Dispatchers.Main) {
                    hubStatusTv.text = "Downloaded $localName. Tap Load to run it on this phone."
                    renderDownloads()
                    renderFiles(repo, listOf(remoteFilename))
                }
            } catch (e: CancellationException) {
                partFile.delete()
                activeDownloads.remove(localName)
                withContext(Dispatchers.Main) {
                    hubStatusTv.text = "Cancelled $localName."
                    renderDownloads()
                }
            } catch (e: Exception) {
                Log.e(TAG, "Download failed", e)
                partFile.delete()
                state.status = "Failed: ${e.message}"
                withContext(Dispatchers.Main) {
                    hubStatusTv.text = "Download failed for $localName: ${e.message}"
                    renderDownloads()
                }
            }
        }

        state.job = job
    }

    private fun updateDownloadUi() {
        lifecycleScope.launch(Dispatchers.Main) {
            if (!isFinishing) renderDownloads()
        }
    }

    private fun renderRepos(repos: List<HubRepo>) {
        reposContainer.removeAllViews()
        if (repos.isEmpty()) return

        reposContainer.addView(sectionLabel("Repositories"))
        repos.forEach { repo ->
            val button = Button(this).apply {
                text = "${repo.id}\nDownloads: ${formatCount(repo.downloads)}  Likes: ${formatCount(repo.likes)}"
                isAllCaps = false
                setOnClickListener { loadRepoFiles(repo) }
            }
            reposContainer.addView(button, matchWrapParams())
        }
    }

    private fun renderFiles(repo: HubRepo, files: List<String>) {
        filesContainer.removeAllViews()
        if (files.isEmpty()) return

        filesContainer.addView(sectionLabel("GGUF files in ${repo.id}"))
        files.forEach { remoteFilename ->
            val localName = safeBasename(remoteFilename)
            val localFile = File(ensureModelsDirectory(), localName)

            val card = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(0, 8, 0, 8)
            }
            card.addView(TextView(this).apply {
                text = remoteFilename
                setTypeface(typeface, Typeface.BOLD)
            })
            card.addView(TextView(this).apply {
                text = mobileModelHint(remoteFilename)
            })

            val actions = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            if (localFile.exists()) {
                actions.addView(Button(this).apply {
                    text = "Load"
                    setOnClickListener { loadDownloadedModel(localFile) }
                })
                actions.addView(Button(this).apply {
                    text = "Delete"
                    setOnClickListener {
                        localFile.delete()
                        renderDownloads()
                        renderFiles(repo, files)
                    }
                })
            } else {
                actions.addView(Button(this).apply {
                    text = if (activeDownloads.containsKey(localName)) "Downloading" else "Download"
                    isEnabled = !activeDownloads.containsKey(localName)
                    setOnClickListener { startModelDownload(repo, remoteFilename) }
                })
            }

            card.addView(actions)
            filesContainer.addView(card, matchWrapParams())
        }
    }

    private fun renderDownloads() {
        downloadsContainer.removeAllViews()

        val modelFiles = ensureModelsDirectory()
            .listFiles { file -> file.isFile && file.name.endsWith(FILE_EXTENSION_GGUF, ignoreCase = true) }
            ?.sortedBy { it.name.lowercase() }
            ?: emptyList()

        if (activeDownloads.isEmpty() && modelFiles.isEmpty()) return

        downloadsContainer.addView(sectionLabel("Downloads and local models"))

        activeDownloads.values.forEach { state ->
            val card = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(0, 8, 0, 8)
            }
            card.addView(TextView(this).apply {
                text = "${state.filename} - ${state.status}"
                setTypeface(typeface, Typeface.BOLD)
            })
            card.addView(ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
                max = 100
                progress = state.percent()
            })
            card.addView(TextView(this).apply {
                text = "${formatBytes(state.downloadedBytes)} / ${if (state.totalBytes > 0) formatBytes(state.totalBytes) else "unknown"}"
            })
            card.addView(Button(this).apply {
                text = if (state.status.startsWith("Failed")) "Remove" else "Cancel"
                setOnClickListener {
                    if (state.status.startsWith("Failed")) {
                        activeDownloads.remove(state.filename)
                        renderDownloads()
                    } else {
                        state.job?.cancel()
                    }
                }
            })
            downloadsContainer.addView(card, matchWrapParams())
        }

        modelFiles
            .filterNot { activeDownloads.containsKey(it.name) }
            .forEach { file ->
                val card = LinearLayout(this).apply {
                    orientation = LinearLayout.VERTICAL
                    setPadding(0, 8, 0, 8)
                }
                card.addView(TextView(this).apply {
                    text = "${file.name} (${formatBytes(file.length())})"
                    setTypeface(typeface, Typeface.BOLD)
                })
                if (file.length() >= LARGE_MODEL_WARNING_BYTES) {
                    card.addView(TextView(this).apply {
                        text = "Large model: may fail to load or run slowly on phones."
                    })
                }
                val actions = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
                actions.addView(Button(this).apply {
                    text = "Load"
                    setOnClickListener { loadDownloadedModel(file) }
                })
                actions.addView(Button(this).apply {
                    text = "Delete"
                    setOnClickListener {
                        file.delete()
                        renderDownloads()
                    }
                })
                card.addView(actions)
                downloadsContainer.addView(card, matchWrapParams())
            }
    }

    private fun loadDownloadedModel(modelFile: File) {
        if (!modelFile.exists()) {
            Toast.makeText(this, "Model file is missing.", Toast.LENGTH_SHORT).show()
            renderDownloads()
            return
        }

        setLoadingState("Loading ${modelFile.name}...")
        lifecycleScope.launch(Dispatchers.IO) {
            try {
                val metadataText = FileInputStreamCompat.open(modelFile).use {
                    GgufMetadataReader.create().readStructuredMetadata(it).toString()
                }
                loadModel(modelFile.name, modelFile, metadataText)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to load downloaded model", e)
                withContext(Dispatchers.Main) {
                    setIdleWithoutModel("Failed to load ${modelFile.name}: ${e.message}")
                }
            }
        }
    }

    private suspend fun ensureModelFile(modelName: String, input: InputStream) =
        withContext(Dispatchers.IO) {
            File(ensureModelsDirectory(), modelName).also { file ->
                if (!file.exists()) {
                    Log.i(TAG, "Start copying file to $modelName")
                    withContext(Dispatchers.Main) {
                        userInputEt.hint = "Copying file..."
                    }

                    FileOutputStream(file).use { input.copyTo(it) }
                    Log.i(TAG, "Finished copying file to $modelName")
                } else {
                    Log.i(TAG, "File already exists $modelName")
                }
            }
        }

    private suspend fun loadModel(modelName: String, modelFile: File, metadataText: String? = null) =
        withContext(Dispatchers.IO) {
            Log.i(TAG, "Loading model $modelName")
            withContext(Dispatchers.Main) {
                setLoadingState("Loading model...")
            }

            generationJob?.cancel()
            prepareEngineForModelLoad()
            engine.loadModel(modelFile.path)

            withContext(Dispatchers.Main) {
                isModelReady = true
                userInputEt.hint = "Ask your on-device model..."
                userInputEt.isEnabled = true
                userActionFab.isEnabled = true
                ggufTv.text = metadataText ?: "Loaded model\n$modelName"
                hubStatusTv.text = "Loaded $modelName. Inference now runs on this phone."
            }
        }

    private fun handleUserInput() {
        userInputEt.text.toString().also { userMsg ->
            if (userMsg.isEmpty()) {
                Toast.makeText(this, "Input message is empty!", Toast.LENGTH_SHORT).show()
            } else {
                userInputEt.text = null
                userInputEt.isEnabled = false
                userActionFab.isEnabled = false

                messages.add(Message(UUID.randomUUID().toString(), userMsg, true))
                lastAssistantMsg.clear()
                messages.add(Message(UUID.randomUUID().toString(), lastAssistantMsg.toString(), false))
                messageAdapter.notifyDataSetChanged()

                generationJob = lifecycleScope.launch(Dispatchers.Default) {
                    var emittedToken = false
                    try {
                        engine.sendUserPrompt(userMsg).collect { token ->
                            emittedToken = true
                            withContext(Dispatchers.Main) {
                                val messageCount = messages.size
                                check(messageCount > 0 && !messages[messageCount - 1].isUser)

                                messages.removeAt(messageCount - 1).copy(
                                    content = lastAssistantMsg.append(token).toString()
                                ).let { messages.add(it) }

                                messageAdapter.notifyItemChanged(messages.size - 1)
                            }
                        }
                        if (!emittedToken) {
                            withContext(Dispatchers.Main) {
                                replaceLastAssistantMessage("No response was generated. The model may not support this chat format or the prompt exceeded the phone context window.")
                            }
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Generation failed", e)
                        withContext(Dispatchers.Main) {
                            replaceLastAssistantMessage("Generation failed: ${e.message}")
                        }
                    } finally {
                        withContext(Dispatchers.Main) {
                            userInputEt.isEnabled = isModelReady
                            userActionFab.isEnabled = isModelReady
                        }
                    }
                }
            }
        }
    }

    private suspend fun awaitEngineInitialized() {
        val state = engine.state.first {
            it is InferenceEngine.State.Initialized ||
                it is InferenceEngine.State.ModelReady ||
                it is InferenceEngine.State.Error
        }
        if (state is InferenceEngine.State.Error) {
            throw state.exception
        }
    }

    private suspend fun prepareEngineForModelLoad() {
        awaitEngineInitialized()
        when (engine.state.value) {
            is InferenceEngine.State.ModelReady,
            is InferenceEngine.State.Error -> {
                engine.cleanUp()
                isModelReady = false
            }
            is InferenceEngine.State.Initialized -> {
                isModelReady = false
            }
            else -> {
                error("Inference engine is busy: ${engine.state.value.javaClass.simpleName}")
            }
        }
    }

    private fun replaceLastAssistantMessage(text: String) {
        val messageCount = messages.size
        if (messageCount > 0 && !messages[messageCount - 1].isUser) {
            messages[messageCount - 1] = messages[messageCount - 1].copy(content = text)
            messageAdapter.notifyItemChanged(messageCount - 1)
        } else {
            messages.add(Message(UUID.randomUUID().toString(), text, false))
            messageAdapter.notifyItemInserted(messages.size - 1)
        }
    }

    private fun setLoadingState(message: String) {
        userInputEt.hint = message
        userInputEt.isEnabled = false
        userActionFab.isEnabled = false
        hubStatusTv.text = message
    }

    private fun setIdleWithoutModel(message: String) {
        isModelReady = false
        userInputEt.hint = "Pick or download a GGUF model first."
        userInputEt.isEnabled = false
        userActionFab.isEnabled = false
        hubStatusTv.text = message
    }

    private fun ensureModelsDirectory() =
        File(filesDir, DIRECTORY_MODELS).also {
            if (it.exists() && !it.isDirectory) it.delete()
            if (!it.exists()) it.mkdir()
        }

    private fun sectionLabel(text: String) = TextView(this).apply {
        this.text = text
        setTypeface(typeface, Typeface.BOLD)
        setPadding(0, 12, 0, 4)
    }

    private fun matchWrapParams() = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT
    )

    private fun parseRepos(json: String): List<HubRepo> {
        val array = org.json.JSONArray(json)
        return (0 until array.length()).mapNotNull { index ->
            val obj = array.optJSONObject(index) ?: return@mapNotNull null
            val id = obj.optString("id")
            if (id.isBlank()) return@mapNotNull null
            HubRepo(
                id = id,
                downloads = obj.optLong("downloads", 0L),
                likes = obj.optLong("likes", 0L)
            )
        }
    }

    private fun parseGgufFiles(json: String): List<String> {
        val siblings = JSONObject(json).optJSONArray("siblings") ?: return emptyList()
        return (0 until siblings.length())
            .mapNotNull { siblings.optJSONObject(it)?.optString("rfilename") }
            .filter { it.endsWith(FILE_EXTENSION_GGUF, ignoreCase = true) }
            .sortedBy { it.lowercase() }
    }

    private fun httpGet(url: String): String {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 20_000
            readTimeout = 30_000
            setRequestProperty("User-Agent", "TurboBitQuant-Android")
        }

        val responseCode = connection.responseCode
        val stream = if (responseCode in 200..299) connection.inputStream else connection.errorStream
        val body = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
        if (responseCode !in 200..299) {
            error("HTTP $responseCode: ${body.take(160)}")
        }
        return body
    }

    private fun encodeQuery(value: String) =
        URLEncoder.encode(value, Charsets.UTF_8.name())

    private fun encodePath(path: String) =
        path.split("/").joinToString("/") { encodeQuery(it).replace("+", "%20") }

    private fun safeBasename(path: String) =
        path.substringAfterLast('/').ifBlank { "model-${System.currentTimeMillis()}$FILE_EXTENSION_GGUF" }

    private fun formatCount(value: Long): String =
        when {
            value >= 1_000_000 -> "${value / 1_000_000}M"
            value >= 1_000 -> "${value / 1_000}k"
            else -> value.toString()
        }

    private fun formatBytes(value: Long): String =
        when {
            value >= 1L * 1024 * 1024 * 1024 -> String.format("%.2f GB", value / (1024.0 * 1024.0 * 1024.0))
            value >= 1L * 1024 * 1024 -> String.format("%.1f MB", value / (1024.0 * 1024.0))
            value >= 1L * 1024 -> String.format("%.1f KB", value / 1024.0)
            else -> "$value B"
        }

    private fun mobileModelHint(filename: String): String {
        val lower = filename.lowercase()
        val quality = when {
            "q2" in lower || "q3" in lower || "q4" in lower -> "mobile-friendly quantization"
            "q5" in lower || "q6" in lower || "q8" in lower -> "larger quantization"
            else -> "check file size before downloading"
        }
        val sizeHint = if (
            "7b" in lower || "8b" in lower || "12b" in lower || "14b" in lower ||
            "27b" in lower || "32b" in lower || "70b" in lower
        ) {
            " May exceed phone RAM."
        } else {
            ""
        }
        return "$quality.$sizeHint"
    }

    override fun onStop() {
        generationJob?.cancel()
        super.onStop()
    }

    override fun onDestroy() {
        activeDownloads.values.forEach { it.job?.cancel() }
        if (::engine.isInitialized) {
            engine.destroy()
        }
        super.onDestroy()
    }

    companion object {
        private val TAG = MainActivity::class.java.simpleName

        private const val HF_API_MODELS = "https://huggingface.co/api/models"
        private const val DIRECTORY_MODELS = "models"
        private const val ASSET_DIRECTORY_MODELS = "models"
        private const val FILE_EXTENSION_GGUF = ".gguf"
        private const val DOWNLOAD_UI_INTERVAL_MS = 500L
        private const val DOWNLOAD_BUFFER_SIZE = 64 * 1024
        private const val LARGE_MODEL_WARNING_BYTES = 3L * 1024 * 1024 * 1024
    }
}

data class HubRepo(
    val id: String,
    val downloads: Long,
    val likes: Long
)

data class DownloadState(
    val filename: String,
    val repoId: String,
    val remoteFilename: String,
    val file: File,
    var downloadedBytes: Long = 0L,
    var totalBytes: Long = 0L,
    var status: String = "Queued",
    var job: Job? = null
) {
    fun percent(): Int =
        if (totalBytes <= 0L) 0 else ((downloadedBytes * 100L) / totalBytes).coerceIn(0L, 100L).toInt()
}

fun GgufMetadata.filename() = when {
    basic.name != null -> {
        basic.name?.let { name ->
            basic.sizeLabel?.let { size ->
                "$name-$size"
            } ?: name
        }
    }
    architecture?.architecture != null -> {
        architecture?.architecture?.let { arch ->
            basic.uuid?.let { uuid ->
                "$arch-$uuid"
            } ?: "$arch-${System.currentTimeMillis()}"
        }
    }
    else -> {
        "model-${System.currentTimeMillis().toString(16)}"
    }
}

private object FileInputStreamCompat {
    fun open(file: File): InputStream = file.inputStream()
}
