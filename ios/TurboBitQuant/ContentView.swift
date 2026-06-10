import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel()
    @State private var selectedTab = "chat"
    @State private var showingFilePicker = false
    @State private var contextSize: Int32 = 4096
    
    // Theme Colors
    private let bgBase = Color(red: 10/255, green: 11/255, blue: 14/255)
    private let bgSurface = Color(red: 18/255, green: 20/255, blue: 26/255)
    private let primaryColor = Color(red: 99/255, green: 102/255, blue: 241/255)
    private let accentColor = Color(red: 6/255, green: 182/255, blue: 212/255)
    private let borderActive = Color(red: 99/255, green: 102/255, blue: 241/255).opacity(0.3)
    private let textMuted = Color(red: 156/255, green: 163/255, blue: 175/255)
    
    var body: some View {
        NavigationView {
            ZStack {
                bgBase.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Header Bar
                    headerBar
                    
                    // Main Viewport
                    switch selectedTab {
                    case "chat":
                        chatTab
                    case "hub":
                        modelHubTab
                    case "bench":
                        benchmarkTab
                    case "settings":
                        settingsTab
                    default:
                        chatTab
                    }
                    
                    // Bottom Custom Tab Navigation
                    customTabBar
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showingFilePicker) {
                DocumentPicker(types: [.data]) { url in
                    viewModel.importModelFromURL(url)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
    
    // MARK: - Header
    
    private var headerBar: some View {
        HStack {
            Image(systemName: "cpu.fill")
                .font(.title2)
                .foregroundColor(primaryColor)
                .shadow(color: primaryColor, radius: 4)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("TurboBitQuant")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                statusSubtitle
            }
            
            Spacer()
            
            if case .modelReady(let name) = viewModel.state {
                Button(action: { viewModel.unloadModel() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "eject.fill")
                        Text("Unload")
                    }
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.8))
                    .cornerRadius(8)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(bgSurface.opacity(0.7).blur(radius: 0.5))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color.white.opacity(0.08)), alignment: .bottom)
    }
    
    private var statusSubtitle: some View {
        HStack(spacing: 6) {
            Circle()
                .frame(width: 8, height: 8)
                .foregroundColor(statusDotColor)
                .shadow(color: statusDotColor, radius: 2)
            
            Text(statusText)
                .font(.caption2)
                .foregroundColor(textMuted)
        }
    }
    
    private var statusDotColor: Color {
        switch viewModel.state {
        case .uninitialized, .error:
            return .red
        case .initializing, .loadingModel, .unloadingModel, .processingSystemPrompt, .processingUserPrompt, .generating, .benchmarking:
            return .orange
        case .initialized, .modelReady:
            return .green
        }
    }
    
    private var statusText: String {
        switch viewModel.state {
        case .uninitialized:
            return "Uninitialized"
        case .initializing:
            return "Initializing backend..."
        case .initialized:
            return "Ready. Load a model."
        case .loadingModel:
            return "Loading model weights..."
        case .unloadingModel:
            return "Unloading model..."
        case .modelReady(let name):
            return "Active: \(name)"
        case .processingSystemPrompt:
            return "Ingesting system instructions..."
        case .processingUserPrompt:
            return "Analyzing user prompt..."
        case .generating:
            return "Generating tokens..."
        case .benchmarking:
            return "Running benchmarks..."
        case .error(let msg):
            return "Error: \(msg)"
        }
    }
    
    // MARK: - Chat Tab
    
    private var chatTab: some View {
        VStack(spacing: 0) {
            if viewModel.messages.isEmpty {
                ScrollView {
                    VStack(spacing: 20) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 60))
                            .foregroundColor(primaryColor.opacity(0.5))
                            .padding(.top, 80)
                        
                        Text("Welcome to TurboBitQuant Chat Suite")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                        
                        Text("Perform hardware-accelerated local GGUF inference directly on your iOS device.")
                            .font(.subheadline)
                            .foregroundColor(textMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Quick Start Instructions:")
                                .font(.headline)
                                .foregroundColor(primaryColor)
                            
                            Label("Go to the **Model Hub** tab.", systemImage: "1.circle.fill")
                            Label("Download a model from Hugging Face, or import one from phone storage.", systemImage: "2.circle.fill")
                            Label("Tap **Load** on your downloaded model.", systemImage: "3.circle.fill")
                            Label("Return here and start chatting offline!", systemImage: "4.circle.fill")
                        }
                        .foregroundColor(.white.opacity(0.8))
                        .font(.footnote)
                        .padding(20)
                        .background(bgSurface.opacity(0.5))
                        .cornerRadius(16)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
                        .padding(.horizontal, 20)
                    }
                }
            } else {
                ScrollViewReader { scrollView in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(viewModel.messages) { message in
                                ChatBubble(message: message, primaryColor: primaryColor, accentColor: accentColor)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 20)
                    }
                    .onChange(of: viewModel.messages.count) { _ in
                        if let lastMessage = viewModel.messages.last {
                            withAnimation {
                                scrollView.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: viewModel.messages.last?.content) { _ in
                        if let lastMessage = viewModel.messages.last, !lastMessage.isUser {
                            scrollView.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            // Input Bar
            chatInputArea
        }
    }
    
    private var chatInputArea: some View {
        HStack(spacing: 12) {
            TextField("Ask your on-device model...", text: $viewModel.userInput)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.3))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
                .foregroundColor(.white)
                .disabled(!isModelLoaded)
            
            Button(action: { viewModel.sendMessage() }) {
                Image(systemName: "paperplane.fill")
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(isModelLoaded && !viewModel.userInput.isEmpty ? primaryColor : Color.white.opacity(0.05))
                    .cornerRadius(12)
            }
            .disabled(!isModelLoaded || viewModel.userInput.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(bgSurface.opacity(0.8))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color.white.opacity(0.08)), alignment: .top)
    }
    
    private var isModelLoaded: Bool {
        if case .modelReady = viewModel.state { return true }
        if case .generating = viewModel.state { return true }
        return false
    }
    
    // MARK: - Model Hub Tab
    
    private var modelHubTab: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Actions (Pick from files)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Local Files Storage")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Button(action: { showingFilePicker = true }) {
                        HStack {
                            Image(systemName: "folder.badge.plus")
                            Text("Pick GGUF from Phone Storage")
                        }
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(accentColor.opacity(0.2))
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(accentColor, lineWidth: 1))
                    }
                }
                .padding(16)
                .background(bgSurface.opacity(0.5))
                .cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
                
                // Hugging Face Search
                VStack(alignment: .leading, spacing: 14) {
                    Text("Hugging Face Model Hub")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    HStack(spacing: 12) {
                        TextField("Search query (e.g. Qwen 0.5B)", text: $viewModel.searchQuery)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.3))
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
                            .foregroundColor(.white)
                        
                        Button(action: { viewModel.searchHuggingFace(query: viewModel.searchQuery) }) {
                            Text("Search")
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(primaryColor)
                                .cornerRadius(10)
                        }
                    }
                    
                    Text(viewModel.searchStatus)
                        .font(.caption)
                        .foregroundColor(textMuted)
                    
                    // Searched Repos
                    if !viewModel.searchedRepos.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Repositories")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(textMuted)
                            
                            ForEach(viewModel.searchedRepos) { repo in
                                Button(action: { viewModel.fetchRepoFiles(repoId: repo.id) }) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(repo.id)
                                                .font(.body)
                                                .foregroundColor(.white)
                                                .multilineTextAlignment(.leading)
                                            
                                            HStack(spacing: 12) {
                                                Label("\(repo.downloads ?? 0)", systemImage: "arrow.down.circle")
                                                Label("\(repo.likes ?? 0)", systemImage: "hand.thumbsup")
                                            }
                                            .font(.caption2)
                                            .foregroundColor(textMuted)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(textMuted)
                                    }
                                    .padding(.vertical, 8)
                                }
                                Divider().background(Color.white.opacity(0.05))
                            }
                        }
                    }
                    
                    // Selected Repo Files
                    if !viewModel.selectedRepoFiles.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("GGUF Files in \(viewModel.selectedRepoId)")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(textMuted)
                            
                            ForEach(viewModel.selectedRepoFiles, id: \.self) { remoteFile in
                                let isDownloaded = localFileExists(remoteFile)
                                
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(remoteFile)
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                    
                                    HStack {
                                        Text(mobileModelHint(remoteFile))
                                            .font(.system(size: 10))
                                            .foregroundColor(textMuted)
                                        
                                        Spacer()
                                        
                                        if isDownloaded {
                                            Text("Ready")
                                                .font(.caption2)
                                                .foregroundColor(.green)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.green.opacity(0.1))
                                                .cornerRadius(6)
                                        } else {
                                            Button(action: { viewModel.startDownload(repoId: viewModel.selectedRepoId, remoteFilename: remoteFile) }) {
                                                Text("Download")
                                                    .font(.caption2)
                                                    .fontWeight(.bold)
                                                    .foregroundColor(.white)
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 6)
                                                    .background(primaryColor)
                                                    .cornerRadius(6)
                                            }
                                        }
                                    }
                                }
                                .padding(10)
                                .background(Color.black.opacity(0.2))
                                .cornerRadius(8)
                            }
                        }
                    }
                }
                .padding(16)
                .background(bgSurface.opacity(0.5))
                .cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
                
                // Downloads Queue
                if !viewModel.activeDownloads.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Active Downloads")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        ForEach(viewModel.activeDownloads) { task in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(task.filename)
                                        .font(.subheadline)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    Spacer()
                                    Button(action: { viewModel.cancelDownload(task: task) }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.red)
                                    }
                                }
                                
                                ProgressView(value: task.progress)
                                    .accentColor(primaryColor)
                                
                                HStack {
                                    Text(task.status)
                                        .font(.caption2)
                                        .foregroundColor(textMuted)
                                    Spacer()
                                    Text("\(formatBytes(task.downloadedBytes)) / \(formatBytes(task.totalBytes))")
                                        .font(.caption2)
                                        .foregroundColor(textMuted)
                                }
                            }
                            .padding(12)
                            .background(Color.black.opacity(0.2))
                            .cornerRadius(10)
                        }
                    }
                    .padding(16)
                    .background(bgSurface.opacity(0.5))
                    .cornerRadius(16)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
                }
                
                // Local Models List
                VStack(alignment: .leading, spacing: 14) {
                    Text("Downloaded Local Models")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    if viewModel.localModelFiles.isEmpty {
                        Text("No GGUF models stored locally yet. Use the Hugging Face search above or copy files from your phone's File storage.")
                            .font(.subheadline)
                            .foregroundColor(textMuted)
                            .padding(.vertical, 10)
                    } else {
                        ForEach(viewModel.localModelFiles, id: \.self) { url in
                            let size = fileSizeOf(url)
                            let isLoaded = currentModelName == url.lastPathComponent
                            
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(url.lastPathComponent)
                                        .font(.subheadline)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    
                                    Spacer()
                                    
                                    Text(formatBytes(size))
                                        .font(.caption2)
                                        .foregroundColor(textMuted)
                                }
                                
                                if size >= 3_000_000_000 {
                                    Text("⚠️ Large model: may fail to load or run slowly on phones.")
                                        .font(.system(size: 10))
                                        .foregroundColor(.orange)
                                }
                                
                                HStack(spacing: 12) {
                                    Button(action: { viewModel.loadModel(fileURL: url, contextSize: contextSize) }) {
                                        Text(isLoaded ? "Reload" : "Load Model")
                                            .font(.caption)
                                            .fontWeight(.bold)
                                            .foregroundColor(.white)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                            .background(isLoaded ? accentColor : primaryColor)
                                            .cornerRadius(8)
                                    }
                                    
                                    Button(action: { viewModel.deleteModel(fileURL: url) }) {
                                        Image(systemName: "trash.fill")
                                            .foregroundColor(.red)
                                            .frame(width: 36, height: 36)
                                            .background(Color.red.opacity(0.1))
                                            .cornerRadius(8)
                                    }
                                }
                            }
                            .padding(12)
                            .background(Color.black.opacity(0.2))
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isLoaded ? accentColor.opacity(0.4) : Color.clear, lineWidth: 1.5))
                        }
                    }
                }
                .padding(16)
                .background(bgSurface.opacity(0.5))
                .cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
            .padding(16)
        }
    }
    
    private var currentModelName: String? {
        if case .modelReady(let name) = viewModel.state { return name }
        return nil
    }
    
    private func localFileExists(_ name: String) -> Bool {
        let cleanName = URL(fileURLWithPath: name).lastPathComponent
        return viewModel.localModelFiles.contains { $0.lastPathComponent == cleanName }
    }
    
    private func fileSizeOf(_ url: URL) -> Int64 {
        do {
            let attribs = try FileManager.default.attributesOfItem(atPath: url.path)
            return attribs[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
    
    private func formatBytes(_ count: Int64) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.2f GB", Double(count) / 1_000_000_000.0)
        } else if count >= 1_000_000 {
            return String(format: "%.1f MB", Double(count) / 1_000_000.0)
        } else if count >= 1024 {
            return String(format: "%.1f KB", Double(count) / 1024.0)
        } else {
            return "\(count) B"
        }
    }
    
    private func mobileModelHint(_ filename: String) -> String {
        let lower = filename.lowercased()
        let quant = if lower.contains("q2") || lower.contains("q3") || lower.contains("q4") {
            "mobile-friendly"
        } else {
            "heavy size"
        }
        let warn = if lower.contains("7b") || lower.contains("8b") || lower.contains("12b") || lower.contains("32b") {
            " - Might run slow or OOM"
        } else {
            ""
        }
        return "\(quant)\(warn)"
    }
    
    // MARK: - Benchmark Tab
    
    private var benchmarkTab: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Model Performance Benchmark")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Text("Runs local evaluations on the currently loaded model using Metal shaders to analyze Prompt Processing (eval) and Token Generation speeds.")
                        .font(.footnote)
                        .foregroundColor(textMuted)
                    
                    Button(action: { viewModel.runBench() }) {
                        HStack {
                            Image(systemName: "chart.bar.xaxis")
                            Text("Run Speed Benchmark")
                        }
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(isModelLoaded ? primaryColor : Color.white.opacity(0.05))
                        .cornerRadius(12)
                    }
                    .disabled(!isModelLoaded)
                }
                .padding(16)
                .background(bgSurface.opacity(0.5))
                .cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
                
                if !viewModel.benchmarkResult.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Results")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(accentColor)
                        
                        Text(viewModel.benchmarkResult)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(14)
                            .background(Color.black.opacity(0.4))
                            .cornerRadius(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                    .background(bgSurface.opacity(0.5))
                    .cornerRadius(16)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
                }
            }
            .padding(16)
        }
    }
    
    // MARK: - Settings Tab
    
    private var settingsTab: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Inference Settings")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("System Instructions / Prompt")
                            .font(.caption)
                            .foregroundColor(textMuted)
                        
                        TextEditor(text: $viewModel.systemPrompt)
                            .frame(height: 100)
                            .padding(8)
                            .background(Color.black.opacity(0.3))
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
                            .foregroundColor(.white)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Context Length (Context Window)")
                            .font(.caption)
                            .foregroundColor(textMuted)
                        
                        Picker("Context Size", selection: $contextSize) {
                            Text("2048 (Recommended)").tag(Int32(2048))
                            Text("4096").tag(Int32(4096))
                            Text("8192").tag(Int32(8192))
                            Text("16384").tag(Int32(16384))
                        }
                        .pickerStyle(.menu)
                        .padding(.vertical, 4)
                    }
                }
                .padding(16)
                .background(bgSurface.opacity(0.5))
                .cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("About TurboBitQuant")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Text("TurboBitQuant leverages C++ llama.cpp bindings directly on iOS. By utilizing Metal GPU computing, the system achieves maximum possible throughput for offline chat and benchmarks.")
                        .font(.footnote)
                        .foregroundColor(textMuted)
                        .lineSpacing(4)
                }
                .padding(16)
                .background(bgSurface.opacity(0.5))
                .cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
            .padding(16)
        }
    }
    
    // MARK: - Tab Bar
    
    private var customTabBar: some View {
        HStack {
            tabButton(title: "Chat Suite", icon: "bubble.left.and.bubble.right.fill", tag: "chat")
            Spacer()
            tabButton(title: "Model Hub", icon: "square.and.arrow.down.fill", tag: "hub")
            Spacer()
            tabButton(title: "Benchmarks", icon: "chart.bar.xaxis", tag: "bench")
            Spacer()
            tabButton(title: "Settings", icon: "gearshape.fill", tag: "settings")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(bgSurface.opacity(0.9))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color.white.opacity(0.08)), alignment: .top)
    }
    
    private func tabButton(title: String, icon: String, tag: String) -> some View {
        Button(action: { selectedTab = tag }) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.system(size: 10))
                    .fontWeight(.medium)
            }
            .foregroundColor(selectedTab == tag ? primaryColor : textMuted)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Bubble View

struct ChatBubble: View {
    let message: Message
    let primaryColor: Color
    let accentColor: Color
    
    var body: some View {
        HStack {
            if message.isUser { Spacer() }
            
            HStack(alignment: .top, spacing: 12) {
                if !message.isUser {
                    Image(systemName: "cpu")
                        .font(.footnote)
                        .foregroundColor(primaryColor)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.05))
                        .clipShape(Circle())
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.content)
                        .font(.body)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(message.isUser ? accentColor.opacity(0.25) : Color.white.opacity(0.05))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(message.isUser ? accentColor.opacity(0.4) : Color.white.opacity(0.08), lineWidth: 1)
                        )
                }
                
                if message.isUser {
                    Image(systemName: "person.fill")
                        .font(.footnote)
                        .foregroundColor(accentColor)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.05))
                        .clipShape(Circle())
                }
            }
            
            if !message.isUser { Spacer() }
        }
    }
}

// MARK: - Document Picker

struct DocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let onPick: (URL) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        
        init(_ parent: DocumentPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.onPick(url)
        }
    }
}
