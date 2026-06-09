// TurboBitQuant - Chat Client Controller

const API_BASE = ""; // Same origin
let conversationHistory = [];
let isGenerating = false;
let statusInterval = null;
let speedChartInstance = null;
let memoryChartInstance = null;
let contextSpeedChartInstance = null;
let systemRamGb = 16.0; // Dynamic detected total system memory
let localModelsMetadata = {};
let activeDownloadPollInterval = null;

// DOM Elements
const modelSelect = document.getElementById("modelSelect");
const contextSelect = document.getElementById("contextSelect");
const startBtn = document.getElementById("startBtn");
const stopBtn = document.getElementById("stopBtn");
const statusDot = document.getElementById("statusDot");
const statusText = document.getElementById("statusText");
const activeModelTitle = document.getElementById("activeModelTitle");
const activeModelSub = document.getElementById("activeModelSub");
const tempInput = document.getElementById("tempInput");
const tempValue = document.getElementById("tempValue");
const tokensInput = document.getElementById("tokensInput");
const tokensValue = document.getElementById("tokensValue");
const tqCheckbox = document.getElementById("tqCheckbox");
const chatMessages = document.getElementById("chatMessages");
const chatForm = document.getElementById("chatForm");
const userInput = document.getElementById("userInput");
const sendBtn = document.getElementById("sendBtn");
const clearChatBtn = document.getElementById("clearChatBtn");

// Multi-model support elements
const activeServersSection = document.getElementById("activeServersSection");
const activeServersList = document.getElementById("activeServersList");
const chatModelSelectorContainer = document.getElementById("chatModelSelectorContainer");
const chatModelSelect = document.getElementById("chatModelSelect");
let selectedChatModel = null;
let currentRunningServers = {};

// Sandbox elements
const tabSandboxBtn = document.getElementById("tabSandboxBtn");
const runCodeBtn = document.getElementById("runCodeBtn");
const importCodeBtn = document.getElementById("importCodeBtn");
const htmlEditor = document.getElementById("htmlEditor");
const cssEditor = document.getElementById("cssEditor");
const jsEditor = document.getElementById("jsEditor");
const previewIframe = document.getElementById("previewIframe");
const previewStatus = document.getElementById("previewStatus");

// Initialize application
document.addEventListener("DOMContentLoaded", async () => {
    // Configure marked options if loaded
    if (typeof marked !== "undefined") {
        marked.setOptions({
            breaks: true,
            gfm: true
        });
    }
    await fetchModels();
    updateMaxTokenCeiling(modelSelect.value);
    await checkServerStatus();
    initTabs();
    initSandbox();
    initHub();
    
    // Start periodic status checking
    statusInterval = setInterval(checkServerStatus, 3000);
    
    // Event Listeners
    startBtn.addEventListener("click", startServer);
    stopBtn.addEventListener("click", stopServer);
    chatForm.addEventListener("submit", sendMessage);
    clearChatBtn.addEventListener("click", clearChat);
    modelSelect.addEventListener("change", () => {
        updateMaxTokenCeiling(modelSelect.value);
    });
    if (contextSelect) {
        contextSelect.addEventListener("change", () => {
            updateMaxTokenCeiling(modelSelect.value);
        });
    }
    if (chatModelSelect) {
        chatModelSelect.addEventListener("change", () => {
            selectedChatModel = chatModelSelect.value;
            updateChatHeaderForSelectedModel();
        });
    }
    
    // UI Sliders
    tempInput.addEventListener("input", (e) => {
        tempValue.textContent = e.target.value;
    });
    tokensInput.addEventListener("input", (e) => {
        tokensValue.textContent = formatTokenCount(e.target.value);
    });
    if (tqCheckbox) {
        tqCheckbox.addEventListener("change", () => {
            updateMaxTokenCeiling(modelSelect.value);
        });
    }
    
    const gpuLayersInput = document.getElementById("gpuLayersInput");
    const gpuLayersValue = document.getElementById("gpuLayersValue");
    if (gpuLayersInput && gpuLayersValue) {
        gpuLayersInput.addEventListener("input", (e) => {
            const val = parseInt(e.target.value);
            if (val === -1) {
                gpuLayersValue.textContent = "Auto";
            } else if (val === 0) {
                gpuLayersValue.textContent = "0 (CPU only)";
            } else if (val === 99) {
                gpuLayersValue.textContent = "99 (Full GPU)";
            } else {
                gpuLayersValue.textContent = val;
            }
        });
    }
    
    // Textarea auto-resize and Enter key binding
    userInput.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && !e.shiftKey) {
            e.preventDefault();
            chatForm.requestSubmit();
        }
    });
    userInput.addEventListener("input", () => {
        userInput.style.height = "auto";
        userInput.style.height = userInput.scrollHeight + "px";
    });
});

// Fetch downloaded models from coordinator
async function fetchModels() {
    try {
        const response = await fetch(`${API_BASE}/api/models`);
        const models = await response.json();
        
        // Populate localModelsMetadata on the fly
        localModelsMetadata = {};
        models.forEach(m => {
            localModelsMetadata[m.filename] = m.size_gb;
        });
        
        modelSelect.innerHTML = "";
        
        if (models.length === 0) {
            modelSelect.innerHTML = `<option value="" disabled selected>No models downloaded yet</option>`;
            startBtn.disabled = true;
            return;
        }
        
        startBtn.disabled = false;
        
        // Group models by family branch
        const gemmaGroup = document.createElement("optgroup");
        gemmaGroup.label = "Gemma Branch (Recommended)";
        const qwenGroup = document.createElement("optgroup");
        qwenGroup.label = "Qwen Branch";
        const deepseekGroup = document.createElement("optgroup");
        deepseekGroup.label = "DeepSeek Branch";
        const otherGroup = document.createElement("optgroup");
        otherGroup.label = "Other Models";
        
        let firstGemmaFilename = null;
        
        models.forEach(m => {
            const opt = document.createElement("option");
            opt.value = m.filename;
            opt.textContent = `${m.filename} (${m.size_gb} GB)`;
            
            const lowerFilename = m.filename.toLowerCase();
            if (lowerFilename.includes("gemma")) {
                gemmaGroup.appendChild(opt);
                if (!firstGemmaFilename) {
                    firstGemmaFilename = m.filename;
                }
            } else if (lowerFilename.includes("deepseek") || lowerFilename.includes("r1")) {
                deepseekGroup.appendChild(opt);
            } else if (lowerFilename.includes("qwen")) {
                qwenGroup.appendChild(opt);
            } else {
                otherGroup.appendChild(opt);
            }
        });
        
        if (gemmaGroup.children.length > 0) modelSelect.appendChild(gemmaGroup);
        if (qwenGroup.children.length > 0) modelSelect.appendChild(qwenGroup);
        if (deepseekGroup.children.length > 0) modelSelect.appendChild(deepseekGroup);
        if (otherGroup.children.length > 0) modelSelect.appendChild(otherGroup);
        
        // Default selection to first Gemma model if present
        if (firstGemmaFilename) {
            modelSelect.value = firstGemmaFilename;
        } else if (models.length > 0) {
            modelSelect.value = models[0].filename;
        }
        
        updateMaxTokenCeiling(modelSelect.value);
    } catch (e) {
        console.error("Failed to fetch models", e);
        modelSelect.innerHTML = `<option value="" disabled selected>Error loading models</option>`;
    }
}

// Check if llama-server backend is running
async function checkServerStatus() {
    try {
        const response = await fetch(`${API_BASE}/api/status`);
        const data = await response.json();
        
        if (data.system_ram_gb) {
            systemRamGb = data.system_ram_gb;
        }
        
        updateServerStatusUI(data.status, data.model, data.running_servers);
    } catch (e) {
        console.error("Failed to check server status", e);
        updateServerStatusUI("Stopped", null, {});
    }
}

// Update sidebar status badge and title
function updateServerStatusUI(status, model, running_servers = {}) {
    currentRunningServers = running_servers;
    const runningCount = Object.keys(running_servers).length;
    
    // Status dot color matches running count
    if (runningCount > 0) {
        statusDot.className = "status-dot running";
        statusText.textContent = `${runningCount} Running`;
    } else {
        statusDot.className = "status-dot stopped";
        statusText.textContent = "Stopped";
    }
    
    // Always keep model selection controls enabled, unless transitioning
    if (status === "Starting" || status === "Stopping") {
        startBtn.disabled = true;
        stopBtn.disabled = true;
        modelSelect.disabled = true;
        if (contextSelect) contextSelect.disabled = true;
    } else {
        startBtn.disabled = false;
        stopBtn.disabled = false;
        modelSelect.disabled = false;
        if (contextSelect) contextSelect.disabled = false;
    }
    
    // Manage stop button visibility
    if (runningCount > 0) {
        stopBtn.classList.remove("hidden");
    } else {
        stopBtn.classList.add("hidden");
    }
    
    // Build Active Servers Sidebar list
    renderActiveServersSidebar(running_servers);
    
    // Update Chat Header Selector
    updateChatModelSelector(running_servers);
}

// Render the list of active servers in the sidebar
function renderActiveServersSidebar(running_servers) {
    if (!activeServersSection || !activeServersList) return;
    
    const models = Object.keys(running_servers);
    if (models.length === 0) {
        activeServersSection.classList.add("hidden");
        activeServersList.innerHTML = "";
        return;
    }
    
    activeServersSection.classList.remove("hidden");
    activeServersList.innerHTML = "";
    
    models.forEach(m => {
        const srv = running_servers[m];
        
        const item = document.createElement("div");
        item.className = "active-server-item";
        
        const info = document.createElement("div");
        info.className = "active-server-info";
        
        const name = document.createElement("div");
        name.className = "active-server-name";
        name.textContent = m;
        name.title = m;
        
        const meta = document.createElement("div");
        meta.className = "active-server-meta";
        meta.textContent = `Port: ${srv.port} • Context: ${formatTokenCount(srv.ctx_size)}`;
        
        info.appendChild(name);
        info.appendChild(meta);
        
        const stopModelBtn = document.createElement("button");
        stopModelBtn.className = "active-server-stop-btn";
        stopModelBtn.innerHTML = `<i class="fa-solid fa-stop"></i>`;
        stopModelBtn.title = "Stop Model Server";
        
        stopModelBtn.addEventListener("click", async () => {
            stopModelBtn.disabled = true;
            try {
                const response = await fetch(`${API_BASE}/api/stop`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ model: m })
                });
                const res = await response.json();
                if (res.error) {
                    alert("Error: " + res.error);
                }
                await checkServerStatus();
            } catch (err) {
                console.error("Failed to stop specific model server", err);
            }
        });
        
        item.appendChild(info);
        item.appendChild(stopModelBtn);
        activeServersList.appendChild(item);
    });
}

// Update the Chat Header dropdown selector options
function updateChatModelSelector(running_servers) {
    if (!chatModelSelectorContainer || !chatModelSelect) return;
    
    const models = Object.keys(running_servers);
    if (models.length === 0) {
        chatModelSelectorContainer.classList.add("hidden");
        chatModelSelect.innerHTML = "";
        selectedChatModel = null;
        
        activeModelTitle.textContent = "No Model Loaded";
        activeModelSub.textContent = "Start the backend server to begin chatting";
        
        userInput.disabled = true;
        sendBtn.disabled = true;
        return;
    }
    
    chatModelSelectorContainer.classList.remove("hidden");
    
    // Save current options list to see if it changed
    const previousOptions = Array.from(chatModelSelect.options).map(o => o.value);
    const optionsChanged = previousOptions.length !== models.length || !models.every(m => previousOptions.includes(m));
    
    if (optionsChanged) {
        chatModelSelect.innerHTML = "";
        models.forEach(m => {
            const opt = document.createElement("option");
            opt.value = m;
            opt.textContent = m;
            chatModelSelect.appendChild(opt);
        });
        
        // Auto-select model if previously selected model is not in running list anymore
        if (!selectedChatModel || !models.includes(selectedChatModel)) {
            selectedChatModel = models[0];
        }
        chatModelSelect.value = selectedChatModel;
    }
    
    updateChatHeaderForSelectedModel();
    
    if (!isGenerating) {
        userInput.disabled = false;
        sendBtn.disabled = false;
    }
}

// Update Chat Header text based on selected model
function updateChatHeaderForSelectedModel() {
    if (!selectedChatModel || !currentRunningServers[selectedChatModel]) return;
    
    const srv = currentRunningServers[selectedChatModel];
    activeModelTitle.textContent = selectedChatModel;
    activeModelSub.textContent = `Running on Port ${srv.port} • Context limit: ${formatTokenCount(srv.ctx_size)} • GPU layers: ${srv.gpu_layers}`;
}

// Start the model backend
async function startServer() {
    const selectedModel = modelSelect.value;
    if (!selectedModel) return;
    
    const useTurboQuant = tqCheckbox ? tqCheckbox.checked : true;
    const contextSize = contextSelect ? parseInt(contextSelect.value) : 4096;
    const gpuLayersInput = document.getElementById("gpuLayersInput");
    const gpuLayers = gpuLayersInput ? parseInt(gpuLayersInput.value) : -1;
    
    updateServerStatusUI("Starting", selectedModel, currentRunningServers);
    
    try {
        const response = await fetch(`${API_BASE}/api/start`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ 
                model: selectedModel,
                turboquant: useTurboQuant,
                ctx_size: contextSize,
                gpu_layers: gpuLayers
            })
        });
        const data = await response.json();
        
        if (data.error) {
            alert("Error starting server: " + data.error);
            checkServerStatus();
        } else {
            checkServerStatus();
        }
    } catch (e) {
        alert("Failed to connect to host coordinator: " + e);
        checkServerStatus();
    }
}

// Stop the model backend (stops all servers)
async function stopServer() {
    updateServerStatusUI("Stopping", null, {});
    try {
        await fetch(`${API_BASE}/api/stop`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({})
        });
        checkServerStatus();
    } catch (e) {
        alert("Failed to stop servers: " + e);
        checkServerStatus();
    }
}

// Clear conversation history
function clearChat() {
    if (isGenerating) return;
    conversationHistory = [];
    chatMessages.innerHTML = `
        <div class="message system-msg welcome-msg">
            <div class="message-icon"><i class="fa-solid fa-robot"></i></div>
            <div class="message-content">
                <h3>Welcome to TurboBitQuant!</h3>
                <p>The conversation history has been cleared. Start a new session by typing below.</p>
            </div>
        </div>
    `;
}

// Send user message and read model response stream
async function sendMessage(e) {
    e.preventDefault();
    if (isGenerating) return;
    
    const text = userInput.value.trim();
    if (!text) return;
    
    userInput.value = "";
    userInput.style.height = "auto";
    
    // Add user message to UI
    appendMessage("user", text);
    
    // Add user message to conversation history
    conversationHistory.push({ role: "user", content: text });
    
    // Create assistant message placeholder in UI
    const botMsgDiv = document.createElement("div");
    botMsgDiv.className = "message bot-msg";
    
    const iconDiv = document.createElement("div");
    iconDiv.className = "message-icon";
    iconDiv.innerHTML = `<i class="fa-solid fa-robot"></i>`;
    botMsgDiv.appendChild(iconDiv);
    
    const contentDiv = document.createElement("div");
    contentDiv.className = "message-content";
    botMsgDiv.appendChild(contentDiv);
    
    // Create typing indicator inside content card
    const indicator = document.createElement("div");
    indicator.className = "typing-indicator";
    indicator.innerHTML = `
        <div class="typing-dot"></div>
        <div class="typing-dot"></div>
        <div class="typing-dot"></div>
    `;
    contentDiv.appendChild(indicator);
    
    chatMessages.appendChild(botMsgDiv);
    scrollToBottom();
    
    // Toggle input state during generation
    isGenerating = true;
    userInput.disabled = true;
    sendBtn.disabled = true;
    
    const maxTokens = parseInt(tokensInput.value);
    const temp = parseFloat(tempInput.value);
    
    let thinkingBox = null;
    let thinkingBody = null;
    let textBody = null;
    let isThinking = false;
    let hasThought = false;
    
    let generatedText = "";
    let thinkingText = "";
    let tokenCount = 0;
    const startTime = Date.now();
    
    try {
        const response = await fetch(`${API_BASE}/api/chat`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                model: selectedChatModel,
                messages: conversationHistory,
                stream: true,
                n_predict: maxTokens,
                temperature: temp
            })
        });
        
        if (!response.ok) {
            const err = await response.json();
            throw new Error(err.error || "Unknown error occurred");
        }
        
        // Remove typing indicator once stream starts
        contentDiv.removeChild(indicator);
        
        // Read stream chunks
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        
        let buffer = "";
        let streamBuffer = "";
        
        while (true) {
            const { value, done } = await reader.read();
            if (done) break;
            
            buffer += decoder.decode(value, { stream: true });
            const lines = buffer.split("\n");
            
            // Keep the last partial line in buffer
            buffer = lines.pop();
            
            for (const line of lines) {
                if (!line.trim() || !line.startsWith("data:")) continue;
                
                try {
                    const jsonStr = line.slice(5).trim();
                    const data = JSON.parse(jsonStr);
                    const token = data.content || "";
                    
                    if (token) {
                        tokenCount++;
                        streamBuffer += token;
                        
                        let processedAnything = true;
                        while (processedAnything) {
                            processedAnything = false;
                            
                            if (!isThinking) {
                                const startTags = ["<think>", "[Start thinking]", "<|channel>thought", "<|channel|>thought"];
                                
                                let foundIdx = -1;
                                let foundLen = 0;
                                for (const tag of startTags) {
                                    const idx = streamBuffer.indexOf(tag);
                                    if (idx !== -1) {
                                        if (foundIdx === -1 || idx < foundIdx) {
                                            foundIdx = idx;
                                            foundLen = tag.length;
                                        }
                                    }
                                }
                                
                                if (foundIdx !== -1) {
                                    // Everything before the tag is regular text
                                    const textBefore = streamBuffer.slice(0, foundIdx);
                                    if (textBefore) {
                                        generatedText += textBefore;
                                        if (!textBody) {
                                            textBody = document.createElement("div");
                                            textBody.className = "markdown-body";
                                            contentDiv.appendChild(textBody);
                                        }
                                        renderMarkdownAndHighlight(textBody, generatedText);
                                    }
                                    
                                    // Transition to thinking state
                                    isThinking = true;
                                    hasThought = true;
                                    
                                    // Create thinking box
                                    thinkingBox = document.createElement("div");
                                    thinkingBox.className = "thinking-box";
                                    
                                    const header = document.createElement("div");
                                    header.className = "thinking-header";
                                    header.innerHTML = `<span><i class="fa-solid fa-brain"></i> Thinking Process</span><i class="fa-solid fa-chevron-down"></i>`;
                                    
                                    thinkingBody = document.createElement("div");
                                    thinkingBody.className = "thinking-body";
                                    
                                    header.addEventListener("click", () => {
                                        header.classList.toggle("collapsed");
                                        thinkingBody.classList.toggle("hidden");
                                    });
                                    
                                    thinkingBox.appendChild(header);
                                    thinkingBox.appendChild(thinkingBody);
                                    contentDiv.appendChild(thinkingBox);
                                    
                                    // Consume the buffer up to after the tag
                                    streamBuffer = streamBuffer.slice(foundIdx + foundLen);
                                    processedAnything = true;
                                } else {
                                    // No start tag found. Check for partial tags at the end of streamBuffer
                                    let safeLen = streamBuffer.length;
                                    for (const tag of startTags) {
                                        for (let i = 1; i < tag.length; i++) {
                                            if (streamBuffer.endsWith(tag.slice(0, i))) {
                                                safeLen = Math.min(safeLen, streamBuffer.length - i);
                                                break;
                                            }
                                        }
                                    }
                                    
                                    if (safeLen > 0) {
                                        const textToProcess = streamBuffer.slice(0, safeLen);
                                        generatedText += textToProcess;
                                        if (!textBody) {
                                            textBody = document.createElement("div");
                                            textBody.className = "markdown-body";
                                            contentDiv.appendChild(textBody);
                                        }
                                        renderMarkdownAndHighlight(textBody, generatedText);
                                        streamBuffer = streamBuffer.slice(safeLen);
                                        processedAnything = true;
                                    }
                                }
                            } else {
                                const endTags = ["</think>", "[End thinking]", "<channel|>", "</|channel|>"];
                                
                                let foundIdx = -1;
                                let foundLen = 0;
                                for (const tag of endTags) {
                                    const idx = streamBuffer.indexOf(tag);
                                    if (idx !== -1) {
                                        if (foundIdx === -1 || idx < foundIdx) {
                                            foundIdx = idx;
                                            foundLen = tag.length;
                                        }
                                    }
                                }
                                
                                if (foundIdx !== -1) {
                                    // Everything before the tag is thinking text
                                    const thinkBefore = streamBuffer.slice(0, foundIdx);
                                    thinkingText += thinkBefore;
                                    if (thinkingBody) {
                                        thinkingBody.textContent = thinkingText;
                                    }
                                    
                                    // Transition to regular text state
                                    isThinking = false;
                                    
                                    // Consume the buffer up to after the tag
                                    streamBuffer = streamBuffer.slice(foundIdx + foundLen);
                                    processedAnything = true;
                                } else {
                                    // No end tag found. Check for partial tags at the end of streamBuffer
                                    let safeLen = streamBuffer.length;
                                    for (const tag of endTags) {
                                        for (let i = 1; i < tag.length; i++) {
                                            if (streamBuffer.endsWith(tag.slice(0, i))) {
                                                safeLen = Math.min(safeLen, streamBuffer.length - i);
                                                break;
                                            }
                                        }
                                    }
                                    
                                    if (safeLen > 0) {
                                        const thinkToProcess = streamBuffer.slice(0, safeLen);
                                        thinkingText += thinkToProcess;
                                        if (thinkingBody) {
                                            thinkingBody.textContent = thinkingText;
                                        }
                                        streamBuffer = streamBuffer.slice(safeLen);
                                        processedAnything = true;
                                    }
                                }
                            }
                        }
                        
                        scrollToBottom();
                    }
                } catch (e) {
                    console.error("Error parsing stream line", e);
                }
            }
        }
        
        // Flush any remaining characters in streamBuffer
        if (streamBuffer) {
            if (isThinking) {
                thinkingText += streamBuffer;
                if (thinkingBody) {
                    thinkingBody.textContent = thinkingText;
                }
            } else {
                generatedText += streamBuffer;
                if (!textBody) {
                    textBody = document.createElement("div");
                    textBody.className = "markdown-body";
                    contentDiv.appendChild(textBody);
                }
                renderMarkdownAndHighlight(textBody, generatedText);
            }
            streamBuffer = "";
        }
        
        // Add final assistant message to conversation history
        const fullResponse = (hasThought ? `[Start thinking]${thinkingText}[End thinking]` : "") + generatedText;
        conversationHistory.push({ role: "assistant", content: fullResponse });
        
        // Add performance speed tag
        const elapsedTime = (Date.now() - startTime) / 1000; // seconds
        const genSpeed = tokenCount / elapsedTime;
        
        const perfTag = document.createElement("div");
        perfTag.className = "performance-tag";
        perfTag.innerHTML = `<i class="fa-solid fa-gauge-high"></i> Speed: ${genSpeed.toFixed(1)} t/s • Time: ${elapsedTime.toFixed(2)}s`;
        contentDiv.appendChild(perfTag);
        
    } catch (e) {
        console.error("Generation failed", e);
        if (indicator.parentNode) {
            contentDiv.removeChild(indicator);
        }
        const errorSpan = document.createElement("span");
        errorSpan.className = "error-text";
        errorSpan.style.color = "var(--status-stopped)";
        errorSpan.innerHTML = `<i class="fa-solid fa-triangle-exclamation"></i> Error: ${e.message}`;
        contentDiv.appendChild(errorSpan);
    } finally {
        isGenerating = false;
        userInput.disabled = false;
        sendBtn.disabled = false;
        userInput.focus();
        scrollToBottom();
    }
}

// Helper function to render Markdown and apply syntax highlighting + copy buttons to code blocks
function renderMarkdownAndHighlight(container, text) {
    if (typeof marked !== 'undefined') {
        container.innerHTML = marked.parse(text);
        
        // Highlight and wrap code blocks
        if (typeof hljs !== 'undefined') {
            container.querySelectorAll('pre code').forEach((block) => {
                hljs.highlightElement(block);
                
                const pre = block.parentNode;
                // Avoid wrapping multiple times if render is called repeatedly
                if (pre && pre.parentNode && !pre.parentNode.classList.contains('code-block-container')) {
                    let lang = 'code';
                    const classes = Array.from(block.classList);
                    const langClass = classes.find(c => c.startsWith('language-'));
                    if (langClass) {
                        lang = langClass.replace('language-', '');
                    }
                    
                    const wrapper = document.createElement('div');
                    wrapper.className = 'code-block-container';
                    
                    const header = document.createElement('div');
                    header.className = 'code-block-header';
                    header.innerHTML = `
                        <span class="code-block-lang">${lang}</span>
                        <button class="code-block-copy-btn"><i class="fa-regular fa-copy"></i> Copy</button>
                    `;
                    
                    const copyBtn = header.querySelector('.code-block-copy-btn');
                    copyBtn.addEventListener('click', () => {
                        const codeText = block.textContent;
                        navigator.clipboard.writeText(codeText).then(() => {
                            copyBtn.classList.add('copied');
                            copyBtn.innerHTML = `<i class="fa-solid fa-check"></i> Copied!`;
                            setTimeout(() => {
                                copyBtn.classList.remove('copied');
                                copyBtn.innerHTML = `<i class="fa-regular fa-copy"></i> Copy`;
                            }, 2000);
                        }).catch(err => {
                            console.error('Failed to copy text: ', err);
                        });
                    });
                    
                    pre.parentNode.insertBefore(wrapper, pre);
                    wrapper.appendChild(header);
                    wrapper.appendChild(pre);
                }
            });
        }
    } else {
        container.textContent = text;
    }
}

// Append a message card to the chat area
function appendMessage(role, text) {
    const msgDiv = document.createElement("div");
    msgDiv.className = `message ${role}-msg`;
    
    const iconDiv = document.createElement("div");
    iconDiv.className = "message-icon";
    iconDiv.innerHTML = role === "user" ? `<i class="fa-solid fa-user"></i>` : `<i class="fa-solid fa-robot"></i>`;
    msgDiv.appendChild(iconDiv);
    
    const contentDiv = document.createElement("div");
    contentDiv.className = "message-content";
    if (role === "user") {
        contentDiv.textContent = text;
    } else {
        renderMarkdownAndHighlight(contentDiv, text);
    }
    msgDiv.appendChild(contentDiv);
    
    chatMessages.appendChild(msgDiv);
    scrollToBottom();
}

// Helper to keep messages scrolled to bottom
function scrollToBottom() {
    chatMessages.scrollTop = chatMessages.scrollHeight;
}

// Tab Switching & Charts Rendering Logic
function initTabs() {
    const tabBtns = document.querySelectorAll(".sidebar-nav .nav-item");
    const tabPanes = document.querySelectorAll(".main-content .tab-pane");
    const refreshPerfBtn = document.getElementById("refreshPerfBtn");
    
    tabBtns.forEach(btn => {
        btn.addEventListener("click", () => {
            const paneId = btn.getAttribute("data-pane");
            
            // Switch tabs active state
            tabBtns.forEach(b => b.classList.remove("active"));
            btn.classList.add("active");
            
            // Switch panes visibility
            tabPanes.forEach(pane => {
                if (pane.id === paneId) {
                    pane.classList.add("active");
                } else {
                    pane.classList.remove("active");
                }
            });
            
            // If switched to performance pane, load charts
            if (paneId === "perfPane") {
                loadPerformanceDashboard();
            }
        });
    });
    
    if (refreshPerfBtn) {
        refreshPerfBtn.addEventListener("click", loadPerformanceDashboard);
    }
}

async function loadPerformanceDashboard() {
    try {
        const response = await fetch(`${API_BASE}/api/benchmarks`);
        const data = await response.json();
        
        renderSpeedChart(data.speeds);
        renderMemoryChart(data.memory);
        renderContextSpeedChart(data.memory);
    } catch (e) {
        console.error("Failed to load benchmark results", e);
    }
}

const chartDefaults = {
    responsive: true,
    maintainAspectRatio: false,
    plugins: {
        legend: {
            labels: {
                color: "#f3f4f6",
                font: {
                    family: "'Outfit', sans-serif",
                    size: 12,
                    weight: 500
                }
            }
        },
        tooltip: {
            backgroundColor: "rgba(18, 20, 26, 0.9)",
            borderColor: "rgba(255, 255, 255, 0.1)",
            borderWidth: 1,
            titleColor: "#f3f4f6",
            titleFont: {
                family: "'Outfit', sans-serif",
                size: 14,
                weight: 600
            },
            bodyColor: "#9ca3af",
            bodyFont: {
                family: "'Outfit', sans-serif",
                size: 13
            },
            padding: 12,
            cornerRadius: 8,
            displayColors: true
        }
    },
    scales: {
        x: {
            grid: {
                color: "rgba(255, 255, 255, 0.05)"
            },
            ticks: {
                color: "#9ca3af",
                font: {
                    family: "'Outfit', sans-serif",
                    size: 11
                }
            }
        },
        y: {
            grid: {
                color: "rgba(255, 255, 255, 0.05)"
            },
            ticks: {
                color: "#9ca3af",
                font: {
                    family: "'Outfit', sans-serif",
                    size: 11
                }
            }
        }
    }
};

function renderSpeedChart(speeds) {
    const ctx = document.getElementById("speedChart").getContext("2d");
    
    if (speedChartInstance) {
        speedChartInstance.destroy();
    }
    
    // Sort speeds by parameters/family
    const order = [
        "0.5B", "0.8B", "1.5B", "E2B", "2B", "3B", "E4B", "4B", "7B", "8B", "9B", "12B", "14B", "26B", "27B", "31B", "32B", "35B", "70B", "72B", "122B", "397B"
    ];
    const sortedSpeeds = [...speeds].sort((a, b) => {
        const idxA = order.findIndex(o => a.model.includes(o));
        const idxB = order.findIndex(o => b.model.includes(o));
        
        // Handle models not in order list
        if (idxA === -1 && idxB === -1) return a.model.localeCompare(b.model);
        if (idxA === -1) return 1;
        if (idxB === -1) return -1;
        
        return idxA - idxB;
    });
    
    const labels = sortedSpeeds.map(s => {
        if (s.model.includes("E2B")) return "Gemma 4 E2B (2.3B)";
        if (s.model.includes("E4B")) return "Gemma 4 E4B (4.5B)";
        if (s.model.includes("12B")) return "Gemma 4 12B (12B)";
        if (s.model.includes("26B")) return "Gemma 4 26B MoE";
        if (s.model.includes("31B")) return "Gemma 4 31B (31B)";
        if (s.model.includes("Qwen")) {
            const match = s.model.match(/Qwen(2\.5|3\.5)?-(\d+(\.\d+)?B)/i);
            if (match) {
                const ver = match[1] ? match[1] : "2.5";
                return `Qwen ${ver} ${match[2]} (Instruct)`;
            }
            return s.model.replace("-GGUF", "").replace("-Instruct", " Instruct");
        }
        if (s.model.includes("DeepSeek-R1")) {
            const match = s.model.match(/DeepSeek-R1-Distill-(Qwen|Llama)-(\d+(\.\d+)?B)/i);
            if (match) return `DeepSeek R1 ${match[1]} ${match[2]} (Reasoning)`;
            return s.model.replace("-GGUF", "").replace("-Distill", " Distill");
        }
        if (s.model.includes("Llama-3.3-70B")) {
            return "Llama 3.3 70B (Instruct)";
        }
        return s.model;
    });
    
    const promptSpeeds = sortedSpeeds.map(s => s.prompt_speed_ts);
    const genSpeeds = sortedSpeeds.map(s => s.gen_speed_ts);
    
    speedChartInstance = new Chart(ctx, {
        type: "bar",
        data: {
            labels: labels,
            datasets: [
                {
                    label: "Prompt Eval Speed (t/s)",
                    data: promptSpeeds,
                    backgroundColor: "rgba(99, 102, 241, 0.7)",
                    borderColor: "#6366f1",
                    borderWidth: 1.5,
                    borderRadius: 6,
                    hoverBackgroundColor: "rgba(99, 102, 241, 0.9)"
                },
                {
                    label: "Token Gen Speed (t/s)",
                    data: genSpeeds,
                    backgroundColor: "rgba(6, 182, 212, 0.7)",
                    borderColor: "#06b6d4",
                    borderWidth: 1.5,
                    borderRadius: 6,
                    hoverBackgroundColor: "rgba(6, 182, 212, 0.9)"
                }
            ]
        },
        options: {
            ...chartDefaults,
            indexAxis: "y",
            scales: {
                x: {
                    ...chartDefaults.scales.x,
                    title: {
                        display: true,
                        text: "Speed (tokens/sec)",
                        color: "#9ca3af",
                        font: { family: "'Outfit', sans-serif", size: 12, weight: 600 }
                    }
                },
                y: {
                    ...chartDefaults.scales.y
                }
            }
        }
    });
}

function renderMemoryChart(memory) {
    const ctx = document.getElementById("memoryChart").getContext("2d");
    
    if (memoryChartInstance) {
        memoryChartInstance.destroy();
    }
    
    const sortedMemory = [...memory].sort((a, b) => a.context_size - b.context_size);
    
    const labels = sortedMemory.map(m => m.context_size >= 1024 ? `${m.context_size / 1024}K` : `${m.context_size}`);
    const f16Mem = sortedMemory.map(m => m.f16_mem_mb);
    const tqMem = sortedMemory.map(m => m.tq_mem_mb);
    
    memoryChartInstance = new Chart(ctx, {
        type: "line",
        data: {
            labels: labels,
            datasets: [
                {
                    label: "Standard FP16 KV Cache",
                    data: f16Mem,
                    borderColor: "#ef4444",
                    backgroundColor: "rgba(239, 68, 68, 0.08)",
                    borderWidth: 3,
                    fill: true,
                    tension: 0.3,
                    pointBackgroundColor: "#ef4444",
                    pointRadius: 4,
                    pointHoverRadius: 6
                },
                {
                    label: "TurboQuant Q4_0 Cache",
                    data: tqMem,
                    borderColor: "#10b981",
                    backgroundColor: "rgba(16, 185, 129, 0.08)",
                    borderWidth: 3,
                    fill: true,
                    tension: 0.3,
                    pointBackgroundColor: "#10b981",
                    pointRadius: 4,
                    pointHoverRadius: 6
                }
            ]
        },
        options: {
            ...chartDefaults,
            scales: {
                x: {
                    ...chartDefaults.scales.x,
                    title: {
                        display: true,
                        text: "Context Size (tokens)",
                        color: "#9ca3af",
                        font: { family: "'Outfit', sans-serif", size: 12, weight: 600 }
                    }
                },
                y: {
                    ...chartDefaults.scales.y,
                    title: {
                        display: true,
                        text: "Peak Memory (MB)",
                        color: "#9ca3af",
                        font: { family: "'Outfit', sans-serif", size: 12, weight: 600 }
                    }
                }
            }
        }
    });
}

function renderContextSpeedChart(memory) {
    const ctx = document.getElementById("contextSpeedChart").getContext("2d");
    
    if (contextSpeedChartInstance) {
        contextSpeedChartInstance.destroy();
    }
    
    const sortedMemory = [...memory].sort((a, b) => a.context_size - b.context_size);
    
    const labels = sortedMemory.map(m => m.context_size >= 1024 ? `${m.context_size / 1024}K` : `${m.context_size}`);
    const f16Gen = sortedMemory.map(m => m.f16_gen_ts);
    const tqGen = sortedMemory.map(m => m.tq_gen_ts);
    
    contextSpeedChartInstance = new Chart(ctx, {
        type: "line",
        data: {
            labels: labels,
            datasets: [
                {
                    label: "Standard FP16 Gen Speed",
                    data: f16Gen,
                    borderColor: "#ef4444",
                    backgroundColor: "rgba(239, 68, 68, 0.02)",
                    borderWidth: 2.5,
                    fill: false,
                    tension: 0.25,
                    pointBackgroundColor: "#ef4444",
                    pointRadius: 4,
                    pointHoverRadius: 6
                },
                {
                    label: "TurboQuant Q4_0 Gen Speed",
                    data: tqGen,
                    borderColor: "#06b6d4",
                    backgroundColor: "rgba(6, 182, 212, 0.02)",
                    borderWidth: 2.5,
                    fill: false,
                    tension: 0.25,
                    pointBackgroundColor: "#06b6d4",
                    pointRadius: 4,
                    pointHoverRadius: 6
                }
            ]
        },
        options: {
            ...chartDefaults,
            scales: {
                x: {
                    ...chartDefaults.scales.x,
                    title: {
                        display: true,
                        text: "Context Size (tokens)",
                        color: "#9ca3af",
                        font: { family: "'Outfit', sans-serif", size: 12, weight: 600 }
                    }
                },
                y: {
                    ...chartDefaults.scales.y,
                    title: {
                        display: true,
                        text: "Speed (tokens/sec)",
                        color: "#9ca3af",
                        font: { family: "'Outfit', sans-serif", size: 12, weight: 600 }
                    }
                }
            }
        }
    });
}

// Format token count cleanly (e.g. 16384 -> "16384 (16K)")
function formatTokenCount(val) {
    const num = parseInt(val);
    if (num >= 1024) {
        return `${num} (${(num / 1024).toFixed(0)}K)`;
    }
    return num;
}

// Dynamically scale the slider's max ceiling based on the selected model size
function updateMaxTokenCeiling(modelName) {
    if (modelName) {
        updateContextLimitOptions(modelName);
    }
    
    const selectedContext = contextSelect ? parseInt(contextSelect.value) : 4096;
    // Cap output tokens at the context size (can scale dynamically up to 131072 depending on context length)
    tokensInput.max = selectedContext;
    
    if (parseInt(tokensInput.value) > selectedContext) {
        tokensInput.value = Math.min(1024, selectedContext);
    }
    tokensValue.textContent = formatTokenCount(tokensInput.value);
}

// Dynamically enable/disable context select options based on model supported limits
function updateContextLimitOptions(modelName) {
    if (!contextSelect) return;
    
    let maxContext = 32768;
    if (modelName.includes("E2B") || modelName.includes("E4B")) {
        maxContext = 262144;
    } else if (modelName.includes("12B") || modelName.includes("26B")) {
        maxContext = 65536;
    } else if (modelName.includes("31B")) {
        maxContext = 32768;
    } else if (modelName.toLowerCase().includes("qwen") || modelName.toLowerCase().includes("deepseek")) {
        maxContext = 131072;
    }
    
    const useTurboQuant = tqCheckbox ? tqCheckbox.checked : true;
    const modelSizeGB = localModelsMetadata[modelName] || 4.0;
    
    let hasSelectedValid = false;
    Array.from(contextSelect.options).forEach(opt => {
        const val = parseInt(opt.value);
        const originalText = getOriginalContextLabel(val);
        
        if (val > maxContext) {
            opt.disabled = true;
            opt.style.display = "none";
            opt.textContent = originalText;
        } else {
            const kvCacheGB = estimateKVCacheSizeGB(modelName, val, useTurboQuant);
            const totalRequiredGB = modelSizeGB + kvCacheGB;
            const ramCeiling = systemRamGb * 0.85;
            
            if (totalRequiredGB > ramCeiling) {
                opt.disabled = true;
                opt.style.display = "block";
                opt.textContent = `${originalText} (Exceeds RAM)`;
                opt.classList.add("ram-warning");
            } else {
                opt.disabled = false;
                opt.style.display = "block";
                opt.textContent = originalText;
                opt.classList.remove("ram-warning");
                if (val === maxContext) {
                    opt.selected = true;
                    hasSelectedValid = true;
                }
            }
        }
    });
    
    if (contextSelect.selectedOptions.length === 0 || contextSelect.selectedOptions[0].disabled) {
        const enabledOpts = Array.from(contextSelect.options).filter(o => !o.disabled);
        if (enabledOpts.length > 0) {
            enabledOpts[enabledOpts.length - 1].selected = true;
        }
    }
}

function getOriginalContextLabel(val) {
    if (val >= 1024) {
        return `${val} (${(val / 1024).toFixed(0)}K)`;
    }
    return val;
}

function estimateKVCacheSizeGB(modelName, contextSize, useTurboQuant) {
    let kbPerToken = 200;
    
    const lower = modelName.toLowerCase();
    if (lower.includes("e2b") || lower.includes("2b") || lower.includes("3b")) {
        kbPerToken = 208;
    } else if (lower.includes("e4b") || lower.includes("7b") || lower.includes("8b") || lower.includes("9b")) {
        kbPerToken = 336;
    } else if (lower.includes("12b") || lower.includes("14b")) {
        kbPerToken = 450;
    } else if (lower.includes("26b") || lower.includes("27b") || lower.includes("31b") || lower.includes("32b") || lower.includes("35b")) {
        kbPerToken = 600;
    } else if (lower.includes("70b") || lower.includes("72b")) {
        kbPerToken = 1200;
    }
    
    let bytesPerToken = kbPerToken * 1024;
    if (useTurboQuant) {
        bytesPerToken = bytesPerToken / 4.0;
    }
    
    const totalBytes = bytesPerToken * contextSize;
    return totalBytes / (1024.0 * 1024.0 * 1024.0);
}

// ==========================================================================
// Hugging Face GGUF Library & Model Downloader Controller
// ==========================================================================
function initHub() {
    const hubSearchForm = document.getElementById("hubSearchForm");
    const hubSearchInput = document.getElementById("hubSearchInput");
    
    if (!hubSearchForm) return;
    
    hubSearchForm.addEventListener("submit", async (e) => {
        e.preventDefault();
        const query = hubSearchInput.value.trim();
        if (!query) return;
        
        await searchHuggingFace(query);
    });
    
    startDownloadPolling();
}

async function searchHuggingFace(query) {
    const hubReposList = document.getElementById("hubReposList");
    const hubRepoDetails = document.getElementById("hubRepoDetails");
    
    hubReposList.innerHTML = `<div class="empty-state"><i class="fa-solid fa-spinner fa-spin empty-icon"></i><p>Searching Hugging Face Hub...</p></div>`;
    hubRepoDetails.innerHTML = `<div class="empty-state"><i class="fa-solid fa-arrow-pointer empty-icon"></i><p>Select a repository from search results to inspect</p></div>`;
    
    try {
        const response = await fetch(`/api/hf/search?q=${encodeURIComponent(query)}`);
        if (!response.ok) throw new Error("Search failed");
        
        const repos = await response.json();
        renderReposList(repos);
    } catch (err) {
        console.error("HF Search error", err);
        hubReposList.innerHTML = `<div class="empty-state"><i class="fa-solid fa-circle-exclamation empty-icon" style="color:var(--status-stopped);"></i><p>Search failed: ${err.message}</p></div>`;
    }
}

function renderReposList(repos) {
    const hubReposList = document.getElementById("hubReposList");
    
    if (repos.length === 0) {
        hubReposList.innerHTML = `<div class="empty-state"><i class="fa-solid fa-magnifying-glass empty-icon"></i><p>No compatible GGUF repositories found matching your query</p></div>`;
        return;
    }
    
    hubReposList.innerHTML = "";
    repos.forEach(repo => {
        const card = document.createElement("div");
        card.className = "repo-card";
        
        const downloadsStr = repo.downloads >= 1000 ? `${(repo.downloads / 1000).toFixed(1)}k` : repo.downloads;
        const likesStr = repo.likes >= 1000 ? `${(repo.likes / 1000).toFixed(1)}k` : repo.likes;
        
        card.innerHTML = `
            <div class="repo-title">${repo.id}</div>
            <div class="repo-meta">
                <span><i class="fa-solid fa-arrow-down"></i> ${downloadsStr}</span>
                <span><i class="fa-solid fa-heart"></i> ${likesStr}</span>
            </div>
        `;
        
        card.addEventListener("click", () => {
            document.querySelectorAll(".repo-card").forEach(c => c.classList.remove("active"));
            card.classList.add("active");
            
            loadRepoDetails(repo.id, repo.likes, repo.downloads);
        });
        
        hubReposList.appendChild(card);
    });
}

async function loadRepoDetails(repoId, likes, downloads) {
    const hubRepoDetails = document.getElementById("hubRepoDetails");
    hubRepoDetails.innerHTML = `<div class="empty-state"><i class="fa-solid fa-spinner fa-spin empty-icon"></i><p>Fetching files from ${repoId}...</p></div>`;
    
    try {
        const response = await fetch(`/api/hf/files?repo=${encodeURIComponent(repoId)}`);
        if (!response.ok) throw new Error("Failed to fetch repository files");
        
        const details = await response.json();
        const ggufFiles = (details.siblings || [])
            .map(s => s.rfilename)
            .filter(name => name.endsWith(".gguf"));
            
        renderRepoDetails(repoId, likes, downloads, ggufFiles);
    } catch (err) {
        console.error("Error loading repo details", err);
        hubRepoDetails.innerHTML = `<div class="empty-state"><i class="fa-solid fa-circle-exclamation empty-icon" style="color:var(--status-stopped);"></i><p>Failed to load details: ${err.message}</p></div>`;
    }
}

function renderRepoDetails(repoId, likes, downloads, ggufFiles) {
    const hubRepoDetails = document.getElementById("hubRepoDetails");
    const downloadsStr = downloads >= 1000 ? `${(downloads / 1000).toFixed(1)}k` : downloads;
    const likesStr = likes >= 1000 ? `${(likes / 1000).toFixed(1)}k` : likes;
    
    let filesHtml = "";
    if (ggufFiles.length === 0) {
        filesHtml = `<div class="empty-state"><i class="fa-solid fa-file-excel empty-icon"></i><p>No GGUF models found in the main branch of this repository.</p></div>`;
    } else {
        filesHtml = `
            <div class="quants-section">
                <h4><i class="fa-solid fa-file-medical"></i> Select Quantization File</h4>
                <div class="quants-list">
                    ${ggufFiles.map(filename => {
                        const displayName = filename.includes("/") ? filename.substring(filename.lastIndexOf("/") + 1) : filename;
                        return `
                            <div class="quant-item">
                                <span class="quant-name" title="${filename}">${displayName}</span>
                                <div class="quant-actions">
                                    <button class="btn btn-primary btn-sm dl-btn" data-repo="${repoId}" data-file="${filename}">
                                        <i class="fa-solid fa-download"></i> Download
                                    </button>
                                </div>
                            </div>
                        `;
                    }).join("")}
                </div>
            </div>
        `;
    }
    
    hubRepoDetails.innerHTML = `
        <div class="repo-details-card">
            <div class="detail-header">
                <div class="detail-title">${repoId.includes("/") ? repoId.split("/")[1] : repoId}</div>
                <div class="detail-author">by ${repoId.includes("/") ? repoId.split("/")[0] : "community"}</div>
                <div class="detail-stats">
                    <span><i class="fa-solid fa-arrow-down"></i> ${downloadsStr} downloads</span>
                    <span><i class="fa-solid fa-heart" style="color: #ef4444; margin-left: 10px;"></i> ${likesStr} likes</span>
                </div>
            </div>
            ${filesHtml}
        </div>
    `;
    
    hubRepoDetails.querySelectorAll(".dl-btn").forEach(btn => {
        btn.addEventListener("click", async () => {
            const repo = btn.getAttribute("data-repo");
            const file = btn.getAttribute("data-file");
            await triggerDownload(repo, file);
        });
    });
}

async function triggerDownload(repo, filename) {
    try {
        const response = await fetch("/api/download/start", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ repo, filename })
        });
        
        if (!response.ok) {
            const err = await response.text();
            throw new Error(err || "Failed to start download");
        }
        
        alert(`Download started for ${filename.includes("/") ? filename.substring(filename.lastIndexOf("/") + 1) : filename}! Progress is tracked below.`);
        startDownloadPolling();
    } catch (err) {
        alert("Error starting download: " + err.message);
    }
}

function startDownloadPolling() {
    if (activeDownloadPollInterval) return;
    pollDownloads();
    activeDownloadPollInterval = setInterval(pollDownloads, 1000);
}

async function pollDownloads() {
    try {
        const response = await fetch("/api/download/status");
        if (!response.ok) return;
        
        const downloads = await response.json();
        renderActiveDownloads(downloads);
    } catch (err) {
        console.error("Error polling downloads", err);
    }
}

function renderActiveDownloads(downloads) {
    const activeDownloadsSection = document.getElementById("activeDownloadsSection");
    const activeDownloadsList = document.getElementById("activeDownloadsList");
    
    if (!activeDownloadsSection || !activeDownloadsList) return;
    
    if (downloads.length === 0) {
        activeDownloadsSection.classList.add("hidden");
        activeDownloadsList.innerHTML = "";
        if (activeDownloadPollInterval) {
            clearInterval(activeDownloadPollInterval);
            activeDownloadPollInterval = null;
        }
        return;
    }
    
    activeDownloadsSection.classList.remove("hidden");
    activeDownloadsList.innerHTML = "";
    
    let hasRunningDownloads = false;
    
    downloads.forEach(dl => {
        const card = document.createElement("div");
        card.className = "download-progress-card";
        
        const downloadedGB = (dl.downloaded_bytes / (1024 * 1024 * 1024)).toFixed(2);
        const totalGB = (dl.total_bytes / (1024 * 1024 * 1024)).toFixed(2);
        
        let statsStr = "";
        let fillClass = "";
        
        if (dl.status.startsWith("Failed")) {
            statsStr = `<span style="color:var(--status-stopped);">${dl.status}</span>`;
            fillClass = "failed";
        } else if (dl.status === "Completed") {
            statsStr = `<span style="color:var(--status-ready);">Completed! Ready.</span>`;
            fillClass = "completed";
            fetchModels();
        } else {
            statsStr = `${downloadedGB} GB / ${totalGB} GB (${dl.percent.toFixed(1)}%)`;
            hasRunningDownloads = true;
        }
        
        card.innerHTML = `
            <div class="progress-header">
                <span class="progress-title">${dl.filename}</span>
                <span class="progress-stats">${statsStr}</span>
            </div>
            <div class="progress-bar-container">
                <div class="progress-bar-fill ${fillClass}" style="width: ${dl.percent}%"></div>
            </div>
            <div class="progress-footer">
                <span class="progress-speed">${dl.status === "Downloading" ? `${dl.speed_mbps.toFixed(1)} MB/s` : ""}</span>
                ${dl.status === "Completed" || dl.status.startsWith("Failed") ? `
                    <button class="progress-cancel-btn" data-file="${dl.filename}"><i class="fa-solid fa-trash-can"></i> Remove</button>
                ` : `
                    <button class="progress-cancel-btn" data-file="${dl.filename}"><i class="fa-solid fa-xmark"></i> Cancel</button>
                `}
            </div>
        `;
        
        card.querySelector(".progress-cancel-btn").addEventListener("click", async () => {
            await cancelDownload(dl.filename);
        });
        
        activeDownloadsList.appendChild(card);
    });
    
    if (!hasRunningDownloads && activeDownloadPollInterval) {
        clearInterval(activeDownloadPollInterval);
        activeDownloadPollInterval = null;
    }
}

async function cancelDownload(filename) {
    try {
        const response = await fetch("/api/download/cancel", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ filename })
        });
        
        if (response.ok) {
            pollDownloads();
            fetchModels();
        }
    } catch (err) {
        console.error("Error cancelling download", err);
    }
}

// ==========================================================================
// Design Canvas HTML/CSS/JS Sandbox Controller
// ==========================================================================
function initSandbox() {
    if (!runCodeBtn || !importCodeBtn) return;
    
    runCodeBtn.addEventListener("click", runCode);
    importCodeBtn.addEventListener("click", importCodeFromChat);
    
    // Preload default sample code on startup if editors are empty
    if (!htmlEditor.value && !cssEditor.value && !jsEditor.value) {
        htmlEditor.value = `<!-- Welcome to the Design Canvas Sandbox! -->
<div class="card">
    <div class="glow"></div>
    <h2>Gemma 4 Design Canvas</h2>
    <p>This is a live trial-and-error preview workspace. Type HTML, CSS, or JavaScript and click "Run Code" to view your live components.</p>
    <button id="actionBtn" class="premium-btn">Click Counter: <span id="clickCount">0</span></button>
</div>`;

        cssEditor.value = `/* Glassmorphic Premium Stylesheet */
body {
    background: radial-gradient(circle at top left, #1a1c29, #0d0e15);
    color: #f3f4f6;
    font-family: 'Outfit', -apple-system, sans-serif;
    display: flex;
    align-items: center;
    justify-content: center;
    min-height: 100vh;
    margin: 0;
    overflow: hidden;
}

.card {
    position: relative;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.08);
    backdrop-filter: blur(16px);
    padding: 32px;
    border-radius: 20px;
    width: 380px;
    box-shadow: 0 20px 50px rgba(0, 0, 0, 0.4);
    text-align: center;
    overflow: hidden;
    transition: border-color 0.3s;
}

.card:hover {
    border-color: rgba(99, 102, 241, 0.3);
}

.glow {
    position: absolute;
    top: -50px;
    left: -50px;
    width: 150px;
    height: 150px;
    background: #6366f1;
    filter: blur(80px);
    opacity: 0.35;
    pointer-events: none;
}

h2 {
    margin-top: 0;
    font-size: 24px;
    font-weight: 700;
    letter-spacing: -0.5px;
    background: linear-gradient(135deg, #a5b4fc, #6366f1);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
}

p {
    font-size: 14px;
    color: #9ca3af;
    line-height: 1.6;
    margin-bottom: 24px;
}

.premium-btn {
    background: linear-gradient(135deg, #6366f1, #4f46e5);
    color: white;
    border: none;
    padding: 12px 24px;
    border-radius: 10px;
    font-weight: 600;
    cursor: pointer;
    font-size: 14px;
    box-shadow: 0 4px 15px rgba(99, 102, 241, 0.4);
    transition: all 0.2s;
}

.premium-btn:hover {
    transform: translateY(-2px);
    box-shadow: 0 6px 20px rgba(99, 102, 241, 0.6);
}

.premium-btn:active {
    transform: translateY(0);
}`;

        jsEditor.value = `// JavaScript counter action
let clicks = 0;
const btn = document.getElementById("actionBtn");
const counter = document.getElementById("clickCount");

if (btn && counter) {
    btn.addEventListener("click", () => {
        clicks++;
        counter.textContent = clicks;
        
        // Micro-animation hover scale
        btn.style.transform = "scale(0.95)";
        setTimeout(() => {
            btn.style.transform = "scale(1.05)";
        }, 100);
    });
}`;
    }
    
    // Run initial preview
    runCode();
}

function runCode() {
    if (!previewIframe) return;
    
    const html = htmlEditor.value || "";
    const css = cssEditor.value || "";
    const js = jsEditor.value || "";
    
    const srcdoc = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;500;600;700;800&display=swap" rel="stylesheet">
    <style>
        ${css}
    </style>
</head>
<body>
    ${html}
    <script>
        window.onerror = function(msg, url, line) {
            const errDiv = document.createElement("div");
            errDiv.style.cssText = "color: #ef4444; background: #fef2f2; border: 1px solid #fee2e2; padding: 12px; margin: 16px; border-radius: 8px; font-family: monospace; font-size: 13px; line-height: 1.5;";
            errDiv.innerHTML = "<strong>JavaScript Runtime Error:</strong><br>" + msg + " (Line " + line + ")";
            document.body.appendChild(errDiv);
            return false;
        };
        
        try {
            ${js}
        } catch(e) {
            window.onerror(e.message, "", 0);
        }
    </script>
</body>
</html>`;
    
    previewIframe.srcdoc = srcdoc;
    
    if (previewStatus) {
        previewStatus.textContent = "Active";
        previewStatus.className = "preview-status active";
    }
}

function importCodeFromChat() {
    if (conversationHistory.length === 0) {
        alert("No chat messages in history to import from.");
        return;
    }
    
    let lastAssistantMsg = null;
    for (let i = conversationHistory.length - 1; i >= 0; i--) {
        const msg = conversationHistory[i];
        if (msg.role === "assistant" && msg.content.includes("```")) {
            lastAssistantMsg = msg.content;
            break;
        }
    }
    
    if (!lastAssistantMsg) {
        alert("Could not find any code blocks in recent assistant responses.");
        return;
    }
    
    const htmlRegex = /```(?:html|xml)?\n([\s\S]*?)\n```/i;
    const htmlMatch = lastAssistantMsg.match(htmlRegex);
    
    const cssRegex = /```css\n([\s\S]*?)\n```/i;
    const cssMatch = lastAssistantMsg.match(cssRegex);
    
    const jsRegex = /```(?:javascript|js)\n([\s\S]*?)\n```/i;
    const jsMatch = lastAssistantMsg.match(jsRegex);
    
    let importedAny = false;
    
    if (htmlMatch && htmlMatch[1]) {
        htmlEditor.value = htmlMatch[1].trim();
        importedAny = true;
    }
    if (cssMatch && cssMatch[1]) {
        cssEditor.value = cssMatch[1].trim();
        importedAny = true;
    }
    if (jsMatch && jsMatch[1]) {
        jsEditor.value = jsMatch[1].trim();
        importedAny = true;
    }
    
    if (importedAny) {
        runCode();
        if (previewStatus) {
            previewStatus.textContent = "Imported!";
            previewStatus.className = "preview-status active";
            setTimeout(() => {
                if (previewStatus) {
                    previewStatus.textContent = "Active";
                }
            }, 2000);
        }
    } else {
        alert("Found a code block, but couldn't parse it as HTML, CSS, or JavaScript. Ensure blocks are labeled (e.g. \`\`\`html, \`\`\`css, or \`\`\`js).");
    }
}
