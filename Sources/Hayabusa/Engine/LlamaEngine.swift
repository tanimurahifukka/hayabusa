import Foundation
import CLlama

struct GenerationResult {
    let text: String
    let promptTokens: Int
    let completionTokens: Int
}

final class LlamaEngine: InferenceEngine, @unchecked Sendable {
    private let model: OpaquePointer
    private let vocab: OpaquePointer
    private let chatTemplate: String?
    private let queue = DispatchQueue(label: "hayabusa.engine")

    private let sharedContext: OpaquePointer
    private let kvCacheManager: KVCacheManager
    private let perSlotCtx: UInt32
    private let nBatch: Int32

    let modelDescription: String
    let slotCount: Int
    private let isGemmaModel: Bool
    private let stopSequences: [String]

    // --- Scheduler state (accessed only on queue) ---
    private var pendingJobs: [GenerationJob] = []
    private var activeJobs: [Int: GenerationJob] = [:]   // slotIndex -> job
    private var sharedBatch: llama_batch
    private var logitsMap: [(batchIndex: Int32, job: GenerationJob)] = []
    private var schedulerRunning = false

    init(modelPath: String, slotCount: Int = 4, perSlotCtx: UInt32 = 4096) throws {
        llama_backend_init()

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = -1 // All layers to Metal GPU

        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw HayabusaError.modelLoadFailed(modelPath)
        }
        self.model = model

        guard let vocab = llama_model_get_vocab(model) else {
            throw HayabusaError.vocabLoadFailed
        }
        self.vocab = vocab

        // Get model description
        var descBuf = [CChar](repeating: 0, count: 256)
        llama_model_desc(model, &descBuf, 256)
        self.modelDescription = String(cString: descBuf)

        // Get chat template
        if let tmplPtr = llama_model_chat_template(model, nil) {
            self.chatTemplate = String(cString: tmplPtr)
        } else {
            self.chatTemplate = nil
        }

        // Shared context for all slots
        self.slotCount = slotCount
        self.perSlotCtx = perSlotCtx

        // Detect model architecture for optimized parameters
        let isGemma4 = self.modelDescription.lowercased().contains("gemma4")
            || self.modelDescription.lowercased().contains("gemma-4")
            || modelPath.lowercased().contains("gemma-4")
            || modelPath.lowercased().contains("gemma4")
        self.isGemmaModel = isGemma4 || modelPath.lowercased().contains("gemma")

        // Text-based stop sequences as fallback for GGUFs that don't mark
        // stop tokens as EOG (e.g. Gemma 4 <end_of_turn>).
        self.stopSequences = (isGemma4 || modelPath.lowercased().contains("gemma"))
            ? ["<end_of_turn>", "<start_of_turn>"]
            : ["<|im_end|>", "<|im_start|>"]

        var ctxParams = llama_context_default_params()
        let nBatch: Int32 = 2048
        ctxParams.n_ctx = perSlotCtx * UInt32(slotCount)
        ctxParams.n_seq_max = UInt32(slotCount)
        ctxParams.n_batch = UInt32(nBatch)
        ctxParams.n_ubatch = UInt32(nBatch)  // match ubatch to batch for Metal throughput
        ctxParams.offload_kqv = true
        ctxParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED  // Force FA on for all models

        // SWA optimization: Gemma 4 uses interleaved sliding window attention.
        // swa_full=false lets SWA layers use only the sliding window during prefill,
        // dramatically reducing compute for long prompts.
        ctxParams.swa_full = isGemma4 ? false : true

        let nCores = Int32(ProcessInfo.processInfo.processorCount)
        let nThreads = Int32(max(1, min(8, nCores - 2)))
        ctxParams.n_threads = nThreads
        // Use more threads for batch prefill (CPU-heavy phase)
        ctxParams.n_threads_batch = Int32(max(nThreads, min(nCores - 1, 12)))

        // Apply KV cache quantization if configured
        let kvQuantizer = KVCacheQuantizer(mode: KVCacheQuantizerConfig.shared.mode)
        kvQuantizer.apply(to: &ctxParams)

        guard let context = llama_init_from_model(model, ctxParams) else {
            throw HayabusaError.contextCreationFailed
        }
        self.sharedContext = context
        self.nBatch = nBatch
        self.sharedBatch = llama_batch_init(nBatch, 0, Int32(slotCount))

        let memory = llama_get_memory(context)!
        self.kvCacheManager = KVCacheManager(memory: memory, maxSlots: slotCount, perSlotContext: perSlotCtx)
    }

    deinit {
        llama_batch_free(sharedBatch)
        llama_free(sharedContext)
        llama_model_free(model)
        llama_backend_free()
    }

    // MARK: - Public API

    func generate(
        messages: [ChatMessage],
        maxTokens: Int = 2048,
        temperature: Float = 0.7,
        priority: SlotPriority = .low
    ) async throws -> GenerationResult {
        // Tokenize outside queue (vocab is immutable)
        let prompt = formatChatML(messages: messages)
        let tokens = tokenize(text: prompt, addBos: false)

        guard !tokens.isEmpty else {
            throw HayabusaError.tokenizationFailed
        }
        if tokens.count + maxTokens > Int(perSlotCtx) {
            throw HayabusaError.contextExceeded
        }

        return try await withCheckedThrowingContinuation { continuation in
            let job = GenerationJob(
                promptTokens: tokens,
                maxTokens: maxTokens,
                temperature: temperature,
                priority: priority,
                continuation: continuation
            )
            queue.async { [self] in
                pendingJobs.append(job)
                ensureSchedulerRunning()
            }
        }
    }

    func slotSummary() -> [(index: Int, state: String, priority: String, pos: Int32)] {
        kvCacheManager.slotSummary()
    }

    // MARK: - Scheduler (all methods run on queue)

    private func ensureSchedulerRunning() {
        guard !schedulerRunning else { return }
        schedulerRunning = true
        schedulerTick()
    }

    private func schedulerTick() {
        // Phase 1: Admit pending jobs into idle slots
        admitPendingJobs()

        // Phase 2: Run one prompt eval (if any job needs it)
        let didPromptEval = runPromptEvals()

        // Phase 3: Build generation batch for all generating slots
        buildGenerationBatch()

        // Phase 4: Decode combined batch
        if sharedBatch.n_tokens > 0 {
            let rc = llama_decode(sharedContext, sharedBatch)
            if rc != 0 {
                // Fail all jobs in this batch
                for (_, job) in logitsMap {
                    job.fail(error: HayabusaError.decodeFailed)
                }
                // Also fail prompt eval jobs that were in the batch
                if !logitsMap.isEmpty || didPromptEval {
                    // Jobs already failed above; clear state
                }
            } else {
                // Phase 5: Sample all generating jobs
                sampleAllGeneratingJobs()
            }
        }

        // Phase 6: Reap finished jobs
        reapFinishedJobs()

        // Phase 7: Continue or stop
        if !pendingJobs.isEmpty || !activeJobs.isEmpty {
            queue.async { [self] in
                schedulerTick()
            }
        } else {
            schedulerRunning = false
        }
    }

    // Phase 1: Move pending jobs into idle slots
    private func admitPendingJobs() {
        var admitted: [Int] = []
        for (i, job) in pendingJobs.enumerated() {
            guard let slot = kvCacheManager.acquireIdleSlot(priority: job.priority) else {
                break  // no more idle slots
            }
            job.slotHandle = slot
            job.phase = .promptEval
            job.currentPos = 0
            job.promptEvalOffset = 0

            // Create sampler
            let sparams = llama_sampler_chain_default_params()
            guard let sampler = llama_sampler_chain_init(sparams) else {
                job.fail(error: HayabusaError.samplerCreationFailed)
                kvCacheManager.releaseSlot(slot)
                admitted.append(i)
                continue
            }
            if job.temperature < 0.01 {
                llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
            } else {
                llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
                llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
                llama_sampler_chain_add(sampler, llama_sampler_init_temp(job.temperature))
                llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
            }
            job.sampler = sampler

            activeJobs[slot.slotIndex] = job
            admitted.append(i)
        }
        // Remove admitted jobs from pending (reverse order to preserve indices)
        for i in admitted.reversed() {
            pendingJobs.remove(at: i)
        }
    }

    // Phase 2: Run prompt eval for one job at a time
    // Returns true if prompt tokens were added to the batch
    private func runPromptEvals() -> Bool {
        sharedBatch.n_tokens = 0
        logitsMap.removeAll()

        // Find the first job that still needs prompt eval
        guard let (_, job) = activeJobs.first(where: { $0.value.phase == .promptEval }),
              let slot = job.slotHandle else {
            return false
        }

        // Reserve space for generating slots (1 token each)
        let generatingCount = activeJobs.values.filter { $0.phase == .generating }.count
        let available = Int(nBatch) - generatingCount
        guard available > 0 else { return false }

        let remaining = job.promptTokens.count - job.promptEvalOffset
        let chunkSize = min(remaining, available)

        for i in 0..<chunkSize {
            let bIdx = sharedBatch.n_tokens
            let tokenIdx = job.promptEvalOffset + i
            sharedBatch.token[Int(bIdx)] = job.promptTokens[tokenIdx]
            sharedBatch.pos[Int(bIdx)] = job.currentPos
            sharedBatch.n_seq_id[Int(bIdx)] = 1
            sharedBatch.seq_id[Int(bIdx)]![0] = slot.seqId
            sharedBatch.logits[Int(bIdx)] = 0
            sharedBatch.n_tokens += 1
            job.currentPos += 1
        }

        job.promptEvalOffset += chunkSize
        kvCacheManager.advancePos(slot, by: Int32(chunkSize))

        // If this was the last chunk, request logits for the last prompt token and transition to generating
        if job.promptEvalOffset >= job.promptTokens.count {
            let lastIdx = sharedBatch.n_tokens - 1
            sharedBatch.logits[Int(lastIdx)] = 1
            logitsMap.append((batchIndex: lastIdx, job: job))
            job.phase = .generating
            kvCacheManager.setSlotState(slot, state: .generating)
            kvCacheManager.touchSlot(slot)
        }

        return true
    }

    // Phase 3: Add one token per generating slot to the batch
    private func buildGenerationBatch() {
        for (_, job) in activeJobs {
            guard job.phase == .generating, !job.outputTokens.isEmpty else { continue }
            guard let slot = job.slotHandle else { continue }

            let lastToken = job.outputTokens.last!
            let bIdx = sharedBatch.n_tokens
            sharedBatch.token[Int(bIdx)] = lastToken
            sharedBatch.pos[Int(bIdx)] = job.currentPos
            sharedBatch.n_seq_id[Int(bIdx)] = 1
            sharedBatch.seq_id[Int(bIdx)]![0] = slot.seqId
            sharedBatch.logits[Int(bIdx)] = 1
            sharedBatch.n_tokens += 1

            job.currentPos += 1
            kvCacheManager.advancePos(slot, by: 1)

            logitsMap.append((batchIndex: bIdx, job: job))
        }
    }

    // Phase 5: Sample from logits for each generating job
    private func sampleAllGeneratingJobs() {
        for (batchIndex, job) in logitsMap {
            guard job.phase == .generating, let sampler = job.sampler else { continue }

            let newToken = llama_sampler_sample(sampler, sharedContext, batchIndex)

            if llama_vocab_is_eog(vocab, newToken) {
                // Qwen3.5: </think> is marked EOG but we continue past it
                let tokenText = detokenizeSingle(token: newToken)
                if !tokenText.contains("</think>") {
                    job.complete(text: job.textBuffer)
                    continue
                }
            }

            job.outputTokens.append(newToken)
            // CJK chars are often split across tokens; decoding per-token corrupts
            // them to U+FFFD. Accumulate raw bytes and decode only complete sequences.
            job.pendingBytes.append(contentsOf: pieceBytes(token: newToken))
            let (complete, pending) = Self.splitCompleteUTF8(job.pendingBytes)
            if !complete.isEmpty {
                job.textBuffer += String(decoding: complete, as: UTF8.self)
            }
            job.pendingBytes = pending

            // Text-based stop sequence detection — catches GGUFs that don't
            // mark stop tokens as EOG (e.g. Gemma 4 <end_of_turn>).
            if checkStopSequence(job: job) { continue }

            if job.outputTokens.count >= job.maxTokens {
                job.complete(text: job.textBuffer)
            }
        }
    }

    private func checkStopSequence(job: GenerationJob) -> Bool {
        for stop in stopSequences {
            guard let range = job.textBuffer.range(of: stop) else { continue }
            let cleanText = String(job.textBuffer[job.textBuffer.startIndex..<range.lowerBound])
            job.complete(text: cleanText)
            return true
        }
        return false
    }

    // Phase 6: Clean up finished/failed jobs
    private func reapFinishedJobs() {
        let finishedSlots = activeJobs.filter { $0.value.phase == .finished || $0.value.phase == .failed }
        for (slotIndex, job) in finishedSlots {
            if let sampler = job.sampler {
                llama_sampler_free(sampler)
                job.sampler = nil
            }
            if let slot = job.slotHandle {
                kvCacheManager.releaseSlot(slot)
            }
            activeJobs.removeValue(forKey: slotIndex)
        }
    }

    // MARK: - Tokenization (thread-safe, vocab is immutable)

    private func tokenize(text: String, addBos: Bool) -> [llama_token] {
        let utf8Count = text.utf8.count
        let maxTokens = utf8Count + (addBos ? 1 : 0) + 1
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: maxTokens)
        defer { tokens.deallocate() }

        let count = llama_tokenize(
            vocab, text, Int32(utf8Count),
            tokens, Int32(maxTokens),
            addBos, true
        )
        guard count >= 0 else { return [] }
        return (0..<Int(count)).map { tokens[$0] }
    }

    private func pieceBytes(token: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 256)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        }
        guard n > 0 else { return [] }
        return buf[0..<Int(n)].map { UInt8(bitPattern: $0) }
    }

    // Split bytes into a decodable prefix and an incomplete trailing UTF-8 sequence.
    static func splitCompleteUTF8(_ bytes: [UInt8]) -> (complete: [UInt8], pending: [UInt8]) {
        var splitIndex = bytes.count
        var i = bytes.count - 1
        var continuations = 0
        while i >= 0 && continuations < 4 {
            let b = bytes[i]
            if b & 0xC0 == 0x80 {  // continuation byte, keep walking back
                i -= 1
                continuations += 1
                continue
            }
            let needed: Int
            if b & 0x80 == 0x00 { needed = 1 }
            else if b & 0xE0 == 0xC0 { needed = 2 }
            else if b & 0xF0 == 0xE0 { needed = 3 }
            else if b & 0xF8 == 0xF0 { needed = 4 }
            else { needed = 1 }  // invalid lead byte: let the decoder deal with it
            if bytes.count - i < needed {
                splitIndex = i
            }
            break
        }
        return (Array(bytes[..<splitIndex]), Array(bytes[splitIndex...]))
    }

    private func detokenizeSingle(token: llama_token) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        if n > 0 {
            buf[Int(n)] = 0
            return String(cString: buf)
        }
        return ""
    }

    private func detokenize(tokens: [llama_token]) -> String {
        var bytes: [UInt8] = []
        for token in tokens {
            bytes.append(contentsOf: pieceBytes(token: token))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Chat Template

    private func formatChatML(messages: [ChatMessage]) -> String {
        if let formatted = tryApplyTemplate(messages: messages) {
            // Only add think tokens for models that support thinking mode (e.g. Qwen3.5)
            // Gemma 4 does not use <think> tags — appending them wastes tokens and confuses the model
            if !isGemmaModel {
                return formatted + "<think>\n</think>\n"
            }
            return formatted
        }

        // Fallback: construct prompt manually based on model family
        if isGemmaModel {
            // Gemma format: <start_of_turn>role\ncontent<end_of_turn>
            var prompt = ""
            for msg in messages {
                let role = msg.role == "assistant" ? "model" : msg.role
                prompt += "<start_of_turn>\(role)\n\(msg.content)<end_of_turn>\n"
            }
            prompt += "<start_of_turn>model\n"
            return prompt
        }

        // ChatML fallback (Qwen, etc.)
        var prompt = ""
        for msg in messages {
            prompt += "<|im_start|>\(msg.role)\n\(msg.content)<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n<think>\n</think>\n"
        return prompt
    }

    private func tryApplyTemplate(messages: [ChatMessage]) -> String? {
        guard chatTemplate != nil else { return nil }

        var cStrings: [UnsafeMutablePointer<CChar>] = []
        defer { cStrings.forEach { free($0) } }

        var cMessages: [llama_chat_message] = messages.map { msg in
            let role = strdup(msg.role)!
            let content = strdup(msg.content)!
            cStrings.append(role)
            cStrings.append(content)
            return llama_chat_message(role: role, content: content)
        }

        let needed = llama_chat_apply_template(
            chatTemplate, &cMessages, cMessages.count, true, nil, 0
        )

        guard needed > 0 else { return nil }

        var buf = [CChar](repeating: 0, count: Int(needed) + 1)
        let written = llama_chat_apply_template(
            chatTemplate, &cMessages, cMessages.count, true, &buf, Int32(buf.count)
        )

        guard written > 0 else { return nil }
        buf[Int(written)] = 0
        return String(cString: buf)
    }
}
