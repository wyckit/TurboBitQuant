import Foundation
import llama

public enum InferenceState: Equatable {
    case uninitialized
    case initializing
    case initialized
    case loadingModel
    case unloadingModel
    case modelReady(modelName: String)
    case processingSystemPrompt
    case processingUserPrompt
    case generating
    case benchmarking
    case error(String)
    
    public static func == (lhs: InferenceState, rhs: InferenceState) -> Bool {
        switch (lhs, rhs) {
        case (.uninitialized, .uninitialized),
             (.initializing, .initializing),
             (.initialized, .initialized),
             (.loadingModel, .loadingModel),
             (.unloadingModel, .unloadingModel),
             (.processingSystemPrompt, .processingSystemPrompt),
             (.processingUserPrompt, .processingUserPrompt),
             (.generating, .generating),
             (.benchmarking, .benchmarking):
            return true
        case (.modelReady(let a), .modelReady(let b)):
            return a == b
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

actor InferenceEngine {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampling: UnsafeMutablePointer<llama_sampler>?
    private var batch: llama_batch?
    
    private var tokensList: [llama_token] = []
    private var temporaryInvalidCChars: [CChar] = []
    
    private var nCtx: Int32 = 4096
    private var nCur: Int32 = 0
    private var stopPosition: Int32 = 0
    private var systemPromptPosition: Int32 = 0
    private var isAborted = false
    
    // We update this via a callback or observation on the actor
    var onStateChange: ((InferenceState) -> Void)?
    
    init() {
        self.batch = llama_batch_init(512, 0, 1)
    }
    
    deinit {
        cleanupResources()
        if let batch = batch {
            var b = batch
            llama_batch_free(b)
        }
    }
    
    private func updateState(_ state: InferenceState) {
        Task { @MainActor in
            self.onStateChange?(state)
        }
    }
    
    func initializeBackend() {
        updateState(.initializing)
        llama_backend_init()
        updateState(.initialized)
    }
    
    func loadModel(path: String, contextSize: Int32 = 4096) throws {
        cleanupResources()
        updateState(.loadingModel)
        
        guard FileManager.default.fileExists(atPath: path) else {
            let errorMsg = "Model file does not exist at \(path)"
            updateState(.error(errorMsg))
            throw NSError(domain: "InferenceEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        print("[*] Running in Simulator - forcing CPU layers (0 GPU layers)")
        #else
        modelParams.n_gpu_layers = 99 // Offload all layers to Metal GPU
        print("[*] Running on Device - offloading to Metal GPU")
        #endif
        
        guard let loadedModel = llama_model_load_from_file(path, modelParams) else {
            let errorMsg = "Failed to load model from file: \(path)"
            updateState(.error(errorMsg))
            throw NSError(domain: "InferenceEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        self.model = loadedModel
        self.vocab = llama_model_get_vocab(loadedModel)
        self.nCtx = contextSize
        
        let nThreads = max(2, min(4, ProcessInfo.processInfo.processorCount - 2))
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(contextSize)
        ctxParams.n_batch = 512
        ctxParams.n_ubatch = 512
        ctxParams.n_threads = UInt32(nThreads)
        ctxParams.n_threads_batch = UInt32(nThreads)
        
        guard let loadedCtx = llama_init_from_model(loadedModel, ctxParams) else {
            llama_model_free(loadedModel)
            self.model = nil
            let errorMsg = "Failed to initialize context from model"
            updateState(.error(errorMsg))
            throw NSError(domain: "InferenceEngine", code: 3, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        self.context = loadedCtx
        
        let sparams = llama_sampler_chain_default_params()
        self.sampling = llama_sampler_chain_init(sparams)
        // Add temperature sampler
        llama_sampler_chain_add(self.sampling, llama_sampler_init_temp(0.4))
        // Add top-k sampler or default fallback sampler
        llama_sampler_chain_add(self.sampling, llama_sampler_init_dist(UInt32(Date().timeIntervalSince1970)))
        
        resetLongTermStates(clearKvCache: true)
        
        let filename = URL(fileURLWithPath: path).lastPathComponent
        updateState(.modelReady(modelName: filename))
    }
    
    func abortGeneration() {
        self.isAborted = true
    }
    
    func clearKvCache() {
        resetLongTermStates(clearKvCache: true)
    }
    
    func unloadModel() {
        updateState(.unloadingModel)
        cleanupResources()
        updateState(.initialized)
    }
    
    private func cleanupResources() {
        if let sampling = sampling {
            llama_sampler_free(sampling)
            self.sampling = nil
        }
        if let context = context {
            llama_free(context)
            self.context = nil
        }
        if let model = model {
            llama_model_free(model)
            self.model = nil
        }
        self.vocab = nil
    }
    
    private func resetLongTermStates(clearKvCache: Bool) {
        tokensList.removeAll()
        systemPromptPosition = 0
        nCur = 0
        isAborted = false
        if clearKvCache, let context = context {
            llama_memory_clear(llama_get_memory(context), false)
        }
    }
    
    func processSystemPrompt(_ prompt: String) throws {
        guard let context = context, let model = model else {
            throw NSError(domain: "InferenceEngine", code: 4, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
        }
        
        updateState(.processingSystemPrompt)
        resetLongTermStates(clearKvCache: true)
        
        let formattedPrompt = "<|im_start|>system\n\(prompt)<|im_end|>\n"
        let systemTokens = tokenize(text: formattedPrompt, addBos: true)
        
        if systemTokens.count >= nCtx - 4 {
            let errorMsg = "System prompt is too long for context size"
            updateState(.error(errorMsg))
            throw NSError(domain: "InferenceEngine", code: 5, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        guard var batch = batch else { return }
        llama_batch_clear(&batch)
        
        for i in 0..<systemTokens.count {
            llama_batch_add(&batch, systemTokens[i], Int32(i), [0], false)
        }
        
        if llama_decode(context, batch) != 0 {
            let errorMsg = "Failed to decode system prompt tokens"
            updateState(.error(errorMsg))
            throw NSError(domain: "InferenceEngine", code: 6, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        systemPromptPosition = Int32(systemTokens.count)
        nCur = systemPromptPosition
        
        if let modelName = self.modelName() {
            updateState(.modelReady(modelName: modelName))
        }
    }
    
    func startUserPrompt(_ prompt: String, predictLength: Int32 = 1024) -> AsyncStream<String> {
        return AsyncStream { continuation in
            guard let context = self.context, let model = self.model, var batch = self.batch else {
                continuation.finish()
                return
            }
            
            self.isAborted = false
            self.updateState(.processingUserPrompt)
            
            let formattedPrompt = "<|im_start|>user\n\(prompt)<|im_end|>\n<|im_start|>assistant\n"
            let userTokens = self.tokenize(text: formattedPrompt, addBos: false)
            
            let userPromptSize = Int32(userTokens.count)
            if self.nCur + userPromptSize >= self.nCtx - 4 {
                // Perform context shift by removing the older half of KV cache
                self.shiftContext()
            }
            
            llama_batch_clear(&batch)
            for i in 0..<userTokens.count {
                let pos = self.nCur + Int32(i)
                let wantLogit = (i == userTokens.count - 1)
                llama_batch_add(&batch, userTokens[i], pos, [0], wantLogit)
            }
            
            if llama_decode(context, batch) != 0 {
                print("[-] llama_decode failed for user prompt")
                continuation.finish()
                return
            }
            
            self.nCur += userPromptSize
            self.stopPosition = self.nCur + predictLength
            self.temporaryInvalidCChars.removeAll()
            
            self.updateState(.generating)
            
            // Text generation loop
            while !self.isAborted && self.nCur < self.stopPosition {
                if self.nCur >= self.nCtx - 4 {
                    self.shiftContext()
                }
                
                guard let sampling = self.sampling else { break }
                let newTokenId = llama_sampler_sample(sampling, context, batch.n_tokens - 1)
                llama_sampler_accept(sampling, newTokenId, true)
                
                llama_batch_clear(&batch)
                llama_batch_add(&batch, newTokenId, self.nCur, [0], true)
                
                if llama_decode(context, batch) != 0 {
                    print("[-] Failed to decode next token")
                    break
                }
                
                self.nCur += 1
                
                if let vocab = self.vocab, llama_vocab_is_eog(vocab, newTokenId) {
                    break
                }
                
                let piece = self.tokenToPiece(token: newTokenId)
                self.temporaryInvalidCChars.append(contentsOf: piece)
                
                if let string = String(validatingUTF8: self.temporaryInvalidCChars + [0]) {
                    self.temporaryInvalidCChars.removeAll()
                    continuation.yield(string)
                }
            }
            
            self.temporaryInvalidCChars.removeAll()
            if let modelName = self.modelName() {
                self.updateState(.modelReady(modelName: modelName))
            }
            continuation.finish()
        }
    }
    
    func runBenchmark(pp: Int32, tg: Int32, pl: Int32, nr: Int32 = 3) -> String {
        guard let context = context, let model = model, var batch = batch else {
            return "Error: Model not loaded"
        }
        
        updateState(.benchmarking)
        
        var ppAvg: Double = 0
        var tgAvg: Double = 0
        var ppStd: Double = 0
        var tgStd: Double = 0
        
        for _ in 0..<nr {
            llama_batch_clear(&batch)
            for i in 0..<Int(pp) {
                llama_batch_add(&batch, 0, Int32(i), [0], false)
            }
            batch.logits[Int(batch.n_tokens) - 1] = 1
            
            llama_memory_clear(llama_get_memory(context), false)
            let tPpStart = DispatchTime.now().uptimeNanoseconds
            if llama_decode(context, batch) != 0 {
                print("[-] llama_decode failed in benchmark prompt processing")
            }
            llama_synchronize(context)
            let tPpEnd = DispatchTime.now().uptimeNanoseconds
            
            llama_memory_clear(llama_get_memory(context), false)
            let tTgStart = DispatchTime.now().uptimeNanoseconds
            for i in 0..<Int(tg) {
                llama_batch_clear(&batch)
                for j in 0..<Int(pl) {
                    llama_batch_add(&batch, 0, Int32(i), [Int32(j)], true)
                }
                if llama_decode(context, batch) != 0 {
                    print("[-] llama_decode failed in benchmark text generation")
                }
                llama_synchronize(context)
            }
            let tTgEnd = DispatchTime.now().uptimeNanoseconds
            
            let tPp = Double(tPpEnd - tPpStart) / 1_000_000_000.0
            let tTg = Double(tTgEnd - tTgStart) / 1_000_000_000.0
            
            let speedPp = Double(pp) / tPp
            let speedTg = Double(pl * tg) / tTg
            
            ppAvg += speedPp
            tgAvg += speedTg
            ppStd += speedPp * speedPp
            tgStd += speedTg * speedTg
        }
        
        llama_memory_clear(llama_get_memory(context), false)
        
        ppAvg /= Double(nr)
        tgAvg /= Double(nr)
        
        if nr > 1 {
            ppStd = sqrt(ppStd / Double(nr - 1) - ppAvg * ppAvg * Double(nr) / Double(nr - 1))
            tgStd = sqrt(tgStd / Double(nr - 1) - tgAvg * tgAvg * Double(nr) / Double(nr - 1))
        } else {
            ppStd = 0
            tgStd = 0
        }
        
        let desc = modelInfo()
        let modelSize = String(format: "%.2f GiB", Double(llama_model_size(model)) / (1024.0 * 1024.0 * 1024.0))
        let modelParams = String(format: "%.2f B", Double(llama_model_n_params(model)) / 1_000_000_000.0)
        let backend = "Metal"
        
        var result = ""
        result += "| model | size | params | backend | test | t/s |\n"
        result += "| --- | --- | --- | --- | --- | --- |\n"
        result += String(format: "| %@ | %@ | %@ | %@ | pp %d | %.2f ± %.2f |\n", desc, modelSize, modelParams, backend, pp, ppAvg, ppStd)
        result += String(format: "| %@ | %@ | %@ | %@ | tg %d | %.2f ± %.2f |\n", desc, modelSize, modelParams, backend, tg, tgAvg, tgStd)
        
        if let modelName = self.modelName() {
            updateState(.modelReady(modelName: modelName))
        }
        
        return result
    }
    
    private func modelName() -> String? {
        guard let model = model else { return nil }
        let result = UnsafeMutablePointer<Int8>.allocate(capacity: 256)
        result.initialize(repeating: Int8(0), count: 256)
        defer { result.deallocate() }
        let _ = llama_model_desc(model, result, 256)
        return String(cString: result)
    }
    
    private func modelInfo() -> String {
        return modelName() ?? "Unknown Model"
    }
    
    private func shiftContext() {
        guard let context = context else { return }
        let nDiscard = (nCur - systemPromptPosition) / 2
        print("[*] Shifting KV Cache: Discarding \(nDiscard) tokens")
        llama_memory_seq_rm(llama_get_memory(context), 0, systemPromptPosition, systemPromptPosition + nDiscard)
        llama_memory_seq_add(llama_get_memory(context), 0, systemPromptPosition + nDiscard, nCur, -nDiscard)
        nCur -= nDiscard
    }
    
    private func tokenize(text: String, addBos: Bool) -> [llama_token] {
        guard let vocab = vocab else { return [] }
        let utf8Count = text.utf8.count
        let maxTokens = utf8Count + (addBos ? 1 : 0) + 1
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: maxTokens)
        defer { tokens.deallocate() }
        
        let tokenCount = llama_tokenize(vocab, text, Int32(utf8Count), tokens, Int32(maxTokens), addBos, false)
        guard tokenCount > 0 else { return [] }
        
        var swiftTokens: [llama_token] = []
        for i in 0..<tokenCount {
            swiftTokens.append(tokens[Int(i)])
        }
        return swiftTokens
    }
    
    private func tokenToPiece(token: llama_token) -> [CChar] {
        guard let vocab = vocab else { return [] }
        let result = UnsafeMutablePointer<Int8>.allocate(capacity: 8)
        result.initialize(repeating: Int8(0), count: 8)
        defer { result.deallocate() }
        
        let nTokens = llama_token_to_piece(vocab, token, result, 8, 0, false)
        if nTokens < 0 {
            let newCapacity = Int(-nTokens)
            let newResult = UnsafeMutablePointer<Int8>.allocate(capacity: newCapacity)
            newResult.initialize(repeating: Int8(0), count: newCapacity)
            defer { newResult.deallocate() }
            let nNewTokens = llama_token_to_piece(vocab, token, newResult, nTokens, 0, false)
            let bufferPointer = UnsafeBufferPointer(start: newResult, count: Int(nNewTokens))
            return Array(bufferPointer)
        } else {
            let bufferPointer = UnsafeBufferPointer(start: result, count: Int(nTokens))
            return Array(bufferPointer)
        }
    }
}

// Global batch helpers matching LibLlama
func llama_batch_clear(_ batch: inout llama_batch) {
    batch.n_tokens = 0
}

func llama_batch_add(_ batch: inout llama_batch, _ id: llama_token, _ pos: llama_pos, _ seq_ids: [llama_seq_id], _ logits: Bool) {
    let index = Int(batch.n_tokens)
    batch.token[index] = id
    batch.pos[index] = pos
    batch.n_seq_id[index] = Int32(seq_ids.count)
    for i in 0..<seq_ids.count {
        batch.seq_id[index]![Int(i)] = seq_ids[i]
    }
    batch.logits[index] = logits ? 1 : 0
    batch.n_tokens += 1
}
