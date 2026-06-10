import Foundation
import Combine
import SwiftUI

public struct Message: Identifiable, Equatable {
    public var id = UUID()
    public var content: String
    public var isUser: Bool
    
    public init(id: UUID = UUID(), content: String, isUser: Bool) {
        self.id = id
        self.content = content
        self.isUser = isUser
    }
}

public struct HubRepo: Identifiable, Decodable {
    public var id: String
    public var downloads: Int?
    public var likes: Int?
    
    public init(id: String, downloads: Int? = 0, likes: Int? = 0) {
        self.id = id
        self.downloads = downloads
        self.likes = likes
    }
}

public class DownloadTaskWrapper: ObservableObject, Identifiable {
    public var id: String { filename }
    @Published public var filename: String
    @Published public var repoId: String
    @Published public var remoteFilename: String
    @Published public var progress: Double = 0.0
    @Published public var downloadedBytes: Int64 = 0
    @Published public var totalBytes: Int64 = 0
    @Published public var status: String = "Queued"
    
    public var urlSessionTask: URLSessionDownloadTask?
    
    public init(filename: String, repoId: String, remoteFilename: String) {
        self.filename = filename
        self.repoId = repoId
        self.remoteFilename = remoteFilename
    }
}

@MainActor
public class ChatViewModel: ObservableObject {
    @Published public var messages: [Message] = []
    @Published public var userInput: String = ""
    @Published public var state: InferenceState = .uninitialized
    @Published public var systemPrompt: String = "You are a helpful, respectful, and honest assistant."
    
    // Model hub properties
    @Published public var searchQuery: String = ""
    @Published public var searchedRepos: [HubRepo] = []
    @Published public var selectedRepoFiles: [String] = []
    @Published public var selectedRepoId: String = ""
    @Published public var isSearching: Bool = false
    @Published public var searchStatus: String = "Search Hugging Face or pick a GGUF file."
    
    // Downloads & local files
    @Published public var activeDownloads: [DownloadTaskWrapper] = []
    @Published public var localModelFiles: [URL] = []
    @Published public var benchmarkResult: String = ""
    
    private let engine = InferenceEngine()
    private var downloadSession: URLSession!
    private var downloadDelegates: [URL: DownloadTaskWrapper] = [:]
    
    public init() {
        setupSession()
        setupStateObservation()
        loadLocalModels()
        
        Task {
            await engine.initializeBackend()
        }
    }
    
    private func setupSession() {
        let config = URLSessionConfiguration.default
        // Using a custom delegate structure is possible, but we can do progress reporting in the view-model directly using task observation or standard delegate
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        self.downloadSession = URLSession(configuration: config, delegate: DownloadDelegateProxy(self), delegateQueue: queue)
    }
    
    private func setupStateObservation() {
        Task {
            await engine.setOnStateChange { [weak self] newState in
                guard let self = self else { return }
                Task { @MainActor in
                    self.state = newState
                }
            }
        }
    }
    
    // MARK: - Model Picker & Loaders
    
    public func loadLocalModels() {
        let fileManager = FileManager.default
        let documentsURL = getDocumentsDirectory()
        
        do {
            let files = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            self.localModelFiles = files.filter { $0.pathExtension.lowercased() == "gguf" }
                .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
        } catch {
            print("[-] Error listing local GGUF models: \(error)")
        }
    }
    
    public func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    public func importModelFromURL(_ sourceURL: URL) {
        let fileManager = FileManager.default
        let destURL = getDocumentsDirectory().appendingPathComponent(sourceURL.lastPathComponent)
        
        // Use coordination to access external files (e.g. from Files app)
        let shouldStopAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        
        do {
            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destURL)
            loadLocalModels()
            searchStatus = "Imported \(sourceURL.lastPathComponent) successfully."
        } catch {
            print("[-] Failed to copy imported GGUF model: \(error)")
            searchStatus = "Import failed: \(error.localizedDescription)"
        }
    }
    
    public func loadModel(fileURL: URL, contextSize: Int32 = 4096) {
        Task {
            do {
                try await engine.loadModel(path: fileURL.path, contextSize: contextSize)
                try await engine.processSystemPrompt(systemPrompt)
                loadLocalModels()
            } catch {
                print("[-] Failed to load model: \(error)")
            }
        }
    }
    
    public func unloadModel() {
        Task {
            await engine.unloadModel()
        }
    }
    
    public func deleteModel(fileURL: URL) {
        do {
            try FileManager.default.removeItem(at: fileURL)
            loadLocalModels()
            searchStatus = "Deleted model file."
        } catch {
            searchStatus = "Delete failed: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Chat Operations
    
    public func sendMessage() {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let userMessage = Message(content: trimmed, isUser: true)
        messages.append(userMessage)
        
        let assistantMessageId = UUID()
        let assistantPlaceholder = Message(id: assistantMessageId, content: "", isUser: false)
        messages.append(assistantPlaceholder)
        
        userInput = ""
        
        Task {
            let stream = await engine.startUserPrompt(trimmed)
            var responseText = ""
            
            for await token in stream {
                responseText += token
                if let index = messages.firstIndex(where: { $0.id == assistantMessageId }) {
                    messages[index].content = responseText
                }
            }
            
            if responseText.isEmpty {
                if let index = messages.firstIndex(where: { $0.id == assistantMessageId }) {
                    messages[index].content = "No response generated. The model may have run out of memory or has a wrong format."
                }
            }
        }
    }
    
    public func clearChat() {
        messages.removeAll()
        Task {
            await engine.clearKvCache()
        }
    }
    
    // MARK: - Benchmark
    
    public func runBench(pp: Int32 = 512, tg: Int32 = 128, pl: Int32 = 1) {
        benchmarkResult = "Running benchmark (Prompt Evaluation: \(pp), Text Generation: \(tg)). Please wait..."
        Task {
            let result = await engine.runBenchmark(pp: pp, tg: tg, pl: pl)
            self.benchmarkResult = result
        }
    }
    
    // MARK: - Hugging Face Hub Client
    
    public func searchHuggingFace(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        isSearching = true
        searchStatus = "Searching Hugging Face..."
        searchedRepos.removeAll()
        selectedRepoFiles.removeAll()
        
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://huggingface.co/api/models?search=\(encoded)&filter=gguf&sort=downloads&direction=-1&limit=15") else {
            isSearching = false
            searchStatus = "Invalid search query."
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("TurboBitQuant-iOS", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            Task { @MainActor in
                self.isSearching = false
                if let error = error {
                    self.searchStatus = "Search failed: \(error.localizedDescription)"
                    return
                }
                
                guard let data = data else {
                    self.searchStatus = "No data returned."
                    return
                }
                
                do {
                    let repos = try JSONDecoder().decode([HubRepo].self, from: data)
                    self.searchedRepos = repos
                    self.searchStatus = repos.isEmpty ? "No GGUF models found." : "Found \(repos.count) repositories. Select one to show files."
                } catch {
                    self.searchStatus = "Failed to parse models list: \(error.localizedDescription)"
                }
            }
        }.resume()
    }
    
    public func fetchRepoFiles(repoId: String) {
        selectedRepoId = repoId
        searchStatus = "Fetching files for \(repoId)..."
        selectedRepoFiles.removeAll()
        
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoId)") else { return }
        
        var request = URLRequest(url: url)
        request.setValue("TurboBitQuant-iOS", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            Task { @MainActor in
                if let error = error {
                    self.searchStatus = "Failed to get repository: \(error.localizedDescription)"
                    return
                }
                
                guard let data = data else { return }
                
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let siblings = json["siblings"] as? [[String: Any]] {
                        let files = siblings.compactMap { $0["rfilename"] as? String }
                            .filter { $0.lowercased().hasSuffix(".gguf") }
                            .sorted { $0.lowercased() < $1.lowercased() }
                        self.selectedRepoFiles = files
                        self.searchStatus = files.isEmpty ? "No GGUF files in repository." : "\(repoId): Select a file under 3GB for mobile devices."
                    } else {
                        self.searchStatus = "Unexpected API response format."
                    }
                } catch {
                    self.searchStatus = "Failed parsing files list: \(error.localizedDescription)"
                }
            }
        }.resume()
    }
    
    // MARK: - Download Manager
    
    public func startDownload(repoId: String, remoteFilename: String) {
        let filename = URL(fileURLWithPath: remoteFilename).lastPathComponent
        let localURL = getDocumentsDirectory().appendingPathComponent(filename)
        
        if activeDownloads.contains(where: { $0.filename == filename }) {
            searchStatus = "Download already in progress."
            return
        }
        
        if FileManager.default.fileExists(atPath: localURL.path) {
            searchStatus = "\(filename) already downloaded."
            return
        }
        
        let escapedFile = remoteFilename.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        
        guard let url = URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(escapedFile)") else {
            searchStatus = "Invalid download link."
            return
        }
        
        let taskWrapper = DownloadTaskWrapper(filename: filename, repoId: repoId, remoteFilename: remoteFilename)
        taskWrapper.status = "Connecting"
        
        var request = URLRequest(url: url)
        request.setValue("TurboBitQuant-iOS", forHTTPHeaderField: "User-Agent")
        
        let downloadTask = downloadSession.downloadTask(with: request)
        taskWrapper.urlSessionTask = downloadTask
        
        downloadDelegates[url] = taskWrapper
        activeDownloads.append(taskWrapper)
        
        downloadTask.resume()
        searchStatus = "Queued \(filename)."
    }
    
    public func cancelDownload(task: DownloadTaskWrapper) {
        task.urlSessionTask?.cancel()
        activeDownloads.removeAll { $0.filename == task.filename }
        searchStatus = "Cancelled \(task.filename)."
    }
    
    // MARK: - Delegate Proxy Integration
    
    fileprivate func downloadTaskDidWriteData(task: URLSessionDownloadTask, bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let url = task.originalRequest?.url,
              let wrapper = downloadDelegates[url] else { return }
        
        Task { @MainActor in
            wrapper.status = "Downloading"
            wrapper.downloadedBytes = totalBytesWritten
            wrapper.totalBytes = totalBytesExpectedToWrite
            if totalBytesExpectedToWrite > 0 {
                wrapper.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            }
        }
    }
    
    fileprivate func downloadTaskDidFinish(task: URLSessionDownloadTask, location: URL) {
        guard let url = task.originalRequest?.url,
              let wrapper = downloadDelegates[url] else { return }
        
        let fileManager = FileManager.default
        let destinationURL = getDocumentsDirectory().appendingPathComponent(wrapper.filename)
        
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: location, to: destinationURL)
            
            Task { @MainActor in
                wrapper.status = "Completed"
                self.activeDownloads.removeAll { $0.filename == wrapper.filename }
                self.loadLocalModels()
                self.searchStatus = "Finished downloading \(wrapper.filename)!"
            }
        } catch {
            print("[-] Error saving downloaded GGUF: \(error)")
            Task { @MainActor in
                wrapper.status = "Failed: \(error.localizedDescription)"
            }
        }
        
        downloadDelegates.removeValue(forKey: url)
    }
    
    fileprivate func downloadTaskDidCompleteWithError(task: URLSessionTask, error: Error?) {
        guard let url = task.originalRequest?.url,
              let wrapper = downloadDelegates[url] else { return }
        
        if let error = error {
            let nsError = error as NSError
            if nsError.code != NSURLErrorCancelled {
                Task { @MainActor in
                    wrapper.status = "Failed: \(error.localizedDescription)"
                    self.searchStatus = "Download failed: \(error.localizedDescription)"
                }
            }
        }
        
        downloadDelegates.removeValue(forKey: url)
    }
}

// MARK: - URLSession Delegates

private class DownloadDelegateProxy: NSObject, URLSessionDownloadDelegate {
    private let parent: ChatViewModel
    
    init(_ parent: ChatViewModel) {
        self.parent = parent
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        parent.downloadTaskDidWriteData(task: downloadTask, bytesWritten: bytesWritten, totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        parent.downloadTaskDidFinish(task: downloadTask, location: location)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        parent.downloadTaskDidCompleteWithError(task: task, error: error)
    }
}
