import Foundation
import CLlama

/// Metrics tracked by the speculative decoder.
struct SpeculativeMetrics: Sendable {
    var totalDraftTokens: Int = 0
    var acceptedTokens: Int = 0
    var totalGenerations: Int = 0
    var totalCompletionTokens: Int = 0

    var acceptanceRate: Double {
        guard totalDraftTokens > 0 else { return 0 }
        return Double(acceptedTokens) / Double(totalDraftTokens)
    }
}

/// Speculative Decoding engine: uses a small draft model to predict tokens,
/// then verifies them in batch with a larger target model.
///
/// Flow per generation step:
///   1. Draft model generates `speculativeTokens` tokens greedily (fast)
///   2. Target model evaluates all draft tokens in one batch (parallel verify)
///   3. Compare: accept matching prefix, reject from first mismatch
///   4. Continue from accepted position
final class SpeculativeDecoder: InferenceEngine, @unchecked Sendable {
    private let draftEngine: LlamaEngine
    private let targetEngine: LlamaEngine
    private let speculativeTokens: Int
    private let queue = DispatchQueue(label: "hayabusa.speculative")

    // Target model resources (used directly for token-level verify)
    private let targetModel: OpaquePointer
    private let targetVocab: OpaquePointer
    private let targetContext: OpaquePointer
    private let targetKVManager: KVCacheManager

    // Draft model resources
    private let draftModel: OpaquePointer
    private let draftVocab: OpaquePointer
    private let draftContext: OpaquePointer
    private let draftKVManager: KVCacheManager

    private let chatTemplate: String?
    private let perSlotCtx: UInt32
    private let nBatch: Int32 = 2048

    private(set) var metrics = SpeculativeMetrics()

    let modelDescription: String
    let slotCount: Int

    init(
        draftModelPath: String,
        targetModelPath: String,
        slotCount: Int = 2,
        perSlotCtx: UInt32 = 4096,
        speculativeTokens: Int = 4
    ) throws {
        self.speculativeTokens = speculativeTokens
        self.slotCount = slotCount
        self.perSlotCtx = perSlotCtx

        llama_backend_init()

        // --- Load draft model ---
        var draftParams = llama_model_default_params()
        draftParams.n_gpu_layers = -1
        guard let dModel = llama_model_load_from_file(draftModelPath, draftParams) else {
            throw HayabusaError.modelLoadFailed(draftModelPath)
        }
        self.draftModel = dModel
        guard let dVocab = llama_model_get_vocab(dModel) else {
            throw HayabusaError.vocabLoadFailed
        }
        self.draftVocab = dVocab

        var dCtxParams = llama_context_default_params()
        dCtxParams.n_ctx = perSlotCtx * UInt32(slotCount)
        dCtxParams.n_seq_max = UInt32(slotCount)
        dCtxParams.n_batch = UInt32(nBatch)
        dCtxParams.offload_kqv = true
        let nThreads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        dCtxParams.n_threads = nThreads
        dCtxParams.n_threads_batch = nThreads

        guard let dCtx = llama_init_from_model(dModel, dCtxParams) else {
            throw HayabusaError.contextCreationFailed
        }
        self.draftContext = dCtx
        let draftMemory = llama_get_memory(dCtx)!
        self.draftKVManager = KVCacheManager(memory: draftMemory, maxSlots: slotCount, perSlotContext: perSlotCtx)

        // --- Load target model ---
        var targetParams = llama_model_default_params()
        targetParams.n_gpu_layers = -1
        guard let tModel = llama_model_load_from_file(targetModelPath, targetParams) else {
            throw HayabusaError.modelLoadFailed(targetModelPath)
        }
        self.targetModel = tModel
        guard let tVocab = llama_model_get_vocab(tModel) else {
            throw HayabusaError.vocabLoadFailed
        }
        self.targetVocab = tVocab

        if let tmplPtr = llama_model_chat_template(tModel, nil) {
            self.chatTemplate = String(cString: tmplPtr)
        } else {
            self.chatTemplate = nil
        }

        var tCtxParams = llama_context_default_params()
        tCtxParams.n_ctx = perSlotCtx * UInt32(slotCount)
        tCtxParams.n_seq_max = UInt32(slotCount)
        tCtxParams.n_batch = UInt32(nBatch)
        tCtxParams.offload_kqv = true
        tCtxParams.n_threads = nThreads
        tCtxParams.n_threads_batch = nThreads

        guard let tCtx = llama_init_from_model(tModel, tCtxParams) else {
            throw HayabusaError.contextCreationFailed
        }
        self.targetContext = tCtx
        let targetMemory = llama_get_memory(tCtx)!
        self.targetKVManager = KVCacheManager(memory: targetMemory, maxSlots: slotCount, perSlotContext: perSlotCtx)

        // Also create full engines for fallback generate()
        self.draftEngine = try LlamaEngine(modelPath: draftModelPath, slotCount: slotCount, perSlotCtx: perSlotCtx)
        self.targetEngine = try LlamaEngine(modelPath: targetModelPath, slotCount: slotCount, perSlotCtx: perSlotCtx)

        var descBuf = [CChar](repeating: 0, count: 256)
        llama_model_desc(tModel, &descBuf, 256)
        self.modelDescription = "Speculative(\(String(cString: descBuf)))"

        print("[Speculative] Draft: \(draftModelPath)")
        print("[Speculative] Target: \(targetModelPath)")
        print("[Speculative] Lookahead: \(speculativeTokens) tokens")
    }

    deinit {
        llama_free(draftContext)
        llama_model_free(draftModel)
        llama_free(targetContext)
        llama_model_free(targetModel)
        llama_backend_free()
    }

    // MARK: - InferenceEngine

    func generate(
        messages: [ChatMessage],
        maxTokens: Int,
        temperature: Float,
        priority: SlotPriority
    ) async throws -> GenerationResult {
        let prompt = formatChatML(messages: messages)

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let result = try speculativeGenerate(
                        prompt: prompt,
                        maxTokens: maxTokens,
                        temperature: temperature
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func slotSummary() -> [(index: Int, state: String, priority: String, pos: Int32)] {
        targetKVManager.slotSummary()
    }

    func memoryInfo() -> EngineMemoryInfo? {
        targetEngine.memoryInfo()
    }

    // MARK: - Speculative Decoding Core

    /// Run speculative decoding for one request.
    /// Uses seq_id 0 on both draft and target contexts.
    private func speculativeGenerate(
        prompt: String,
        maxTokens: Int,
        temperature: Float
    ) throws -> GenerationResult {
        let promptTokens = tokenize(vocab: targetVocab, text: prompt, addBos: false)
        guard !promptTokens.isEmpty else {
            throw HayabusaError.tokenizationFailed
        }

        let seqId: llama_seq_id = 0

        // Clear KV for both models
        llama_memory_seq_rm(llama_get_memory(draftContext)!, seqId, -1, -1)
        llama_memory_seq_rm(llama_get_memory(targetContext)!, seqId, -1, -1)

        // --- Prompt eval for both models ---
        try evalTokens(context: draftContext, tokens: promptTokens, seqId: seqId, startPos: 0)
        try evalTokens(context: targetContext, tokens: promptTokens, seqId: seqId, startPos: 0)

        var draftPos = Int32(promptTokens.count)
        var targetPos = Int32(promptTokens.count)
        var outputTokens: [llama_token] = []

        // Create greedy samplers
        let draftSampler = createGreedySampler()
        let targetSampler = temperature < 0.01 ? createGreedySampler() : createTempSampler(temperature: temperature)
        defer {
            llama_sampler_free(draftSampler)
            llama_sampler_free(targetSampler)
        }

        // Sample first token from target
        var lastTargetToken = llama_sampler_sample(targetSampler, targetContext, -1)
        if llama_vocab_is_eog(targetVocab, lastTargetToken) {
            return GenerationResult(text: "", promptTokens: promptTokens.count, completionTokens: 0)
        }
        outputTokens.append(lastTargetToken)

        // Also feed this first token to draft model
        try evalTokens(context: draftContext, tokens: [lastTargetToken], seqId: seqId, startPos: draftPos)
        draftPos += 1
        targetPos += 1

        // Main speculative loop
        while outputTokens.count < maxTokens {
            // Step 1: Draft model generates K tokens
            var draftTokens: [llama_token] = []
            for _ in 0..<speculativeTokens {
                let dToken = llama_sampler_sample(draftSampler, draftContext, -1)
                if llama_vocab_is_eog(draftVocab, dToken) { break }
                draftTokens.append(dToken)
                try evalTokens(context: draftContext, tokens: [dToken], seqId: seqId, startPos: draftPos)
                draftPos += 1
            }

            if draftTokens.isEmpty {
                // Draft thinks generation is done, sample one more from target
                try evalTokens(context: targetContext, tokens: [lastTargetToken], seqId: seqId, startPos: targetPos)
                targetPos += 1
                let finalToken = llama_sampler_sample(targetSampler, targetContext, -1)
                if !llama_vocab_is_eog(targetVocab, finalToken) {
                    outputTokens.append(finalToken)
                }
                break
            }

            metrics.totalDraftTokens += draftTokens.count

            // Step 2: Target model verifies all draft tokens in one batch
            let verifyTokens = [lastTargetToken] + draftTokens
            try evalTokensBatch(
                context: targetContext,
                tokens: verifyTokens,
                seqId: seqId,
                startPos: targetPos
            )

            // Step 3: Compare draft vs target at each position
            var acceptedCount = 0
            for i in 0..<draftTokens.count {
                let batchIdx = Int32(i) // logits index for position i in the batch
                let targetToken = llama_sampler_sample(targetSampler, targetContext, batchIdx)

                if targetToken == draftTokens[i] {
                    // Accepted
                    acceptedCount += 1
                    outputTokens.append(draftTokens[i])
                    if llama_vocab_is_eog(targetVocab, targetToken) {
                        break
                    }
                } else {
                    // Rejected: use target's token instead
                    outputTokens.append(targetToken)

                    // Roll back draft model KV cache to the accepted prefix
                    let rollbackPos = targetPos + Int32(acceptedCount) + 1
                    llama_memory_seq_rm(llama_get_memory(draftContext)!, seqId, rollbackPos, -1)
                    draftPos = rollbackPos

                    // Feed the corrected token to draft model
                    try evalTokens(context: draftContext, tokens: [targetToken], seqId: seqId, startPos: draftPos)
                    draftPos += 1
                    break
                }
            }

            // If all draft tokens accepted, sample one bonus token from target
            if acceptedCount == draftTokens.count {
                let bonusBatchIdx = Int32(draftTokens.count)
                let bonusToken = llama_sampler_sample(targetSampler, targetContext, bonusBatchIdx)
                if !llama_vocab_is_eog(targetVocab, bonusToken) {
                    outputTokens.append(bonusToken)
                    try evalTokens(context: draftContext, tokens: [bonusToken], seqId: seqId, startPos: draftPos)
                    draftPos += 1
                }
            }

            // Roll back target KV cache for unaccepted tokens
            let targetAcceptedPos = targetPos + Int32(acceptedCount) + 1
            llama_memory_seq_rm(llama_get_memory(targetContext)!, seqId, targetAcceptedPos, -1)
            targetPos = targetAcceptedPos

            metrics.acceptedTokens += acceptedCount
            lastTargetToken = outputTokens.last!

            // Check for EOG
            if llama_vocab_is_eog(targetVocab, lastTargetToken) {
                outputTokens.removeLast()
                break
            }
        }

        metrics.totalGenerations += 1
        metrics.totalCompletionTokens += outputTokens.count

        let text = detokenize(vocab: targetVocab, tokens: outputTokens)
        return GenerationResult(
            text: text,
            promptTokens: promptTokens.count,
            completionTokens: outputTokens.count
        )
    }

    // MARK: - Eval Helpers

    private func evalTokens(context: OpaquePointer, tokens: [llama_token], seqId: llama_seq_id, startPos: Int32) throws {
        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }

        for (i, token) in tokens.enumerated() {
            batch.token[i] = token
            batch.pos[i] = startPos + Int32(i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = seqId
            batch.logits[i] = (i == tokens.count - 1) ? 1 : 0
        }
        batch.n_tokens = Int32(tokens.count)

        let rc = llama_decode(context, batch)
        if rc != 0 {
            throw HayabusaError.decodeFailed
        }
    }

    /// Eval multiple tokens with logits requested at every position (for verification).
    private func evalTokensBatch(context: OpaquePointer, tokens: [llama_token], seqId: llama_seq_id, startPos: Int32) throws {
        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }

        for (i, token) in tokens.enumerated() {
            batch.token[i] = token
            batch.pos[i] = startPos + Int32(i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = seqId
            batch.logits[i] = 1 // Request logits at every position for verification
        }
        batch.n_tokens = Int32(tokens.count)

        let rc = llama_decode(context, batch)
        if rc != 0 {
            throw HayabusaError.decodeFailed
        }
    }

    // MARK: - Sampler Helpers

    private func createGreedySampler() -> UnsafeMutablePointer<llama_sampler> {
        let sparams = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(sparams)!
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        return chain
    }

    private func createTempSampler(temperature: Float) -> UnsafeMutablePointer<llama_sampler> {
        let sparams = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(sparams)!
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        return chain
    }

    // MARK: - Tokenization

    private func tokenize(vocab: OpaquePointer, text: String, addBos: Bool) -> [llama_token] {
        let utf8Count = text.utf8.count
        let maxTokens = utf8Count + (addBos ? 1 : 0) + 1
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: maxTokens)
        defer { tokens.deallocate() }

        let count = llama_tokenize(vocab, text, Int32(utf8Count), tokens, Int32(maxTokens), addBos, true)
        guard count >= 0 else { return [] }
        return (0..<Int(count)).map { tokens[$0] }
    }

    private func detokenize(vocab: OpaquePointer, tokens: [llama_token]) -> String {
        var result = ""
        for token in tokens {
            var buf = [CChar](repeating: 0, count: 256)
            let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
            if n > 0 {
                buf[Int(n)] = 0
                if let s = String(validatingCString: buf) {
                    result += s
                }
            } else if n < 0 {
                var bigBuf = [CChar](repeating: 0, count: Int(-n) + 1)
                let n2 = llama_token_to_piece(vocab, token, &bigBuf, Int32(bigBuf.count), 0, false)
                if n2 > 0 {
                    bigBuf[Int(n2)] = 0
                    if let s = String(validatingCString: bigBuf) {
                        result += s
                    }
                }
            }
        }
        return result
    }

    // MARK: - Chat Template

    private func formatChatML(messages: [ChatMessage]) -> String {
        if let formatted = tryApplyTemplate(messages: messages) {
            return formatted + "<think>\n</think>\n"
        }
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

        let needed = llama_chat_apply_template(chatTemplate, &cMessages, cMessages.count, true, nil, 0)
        guard needed > 0 else { return nil }

        var buf = [CChar](repeating: 0, count: Int(needed) + 1)
        let written = llama_chat_apply_template(chatTemplate, &cMessages, cMessages.count, true, &buf, Int32(buf.count))
        guard written > 0 else { return nil }
        buf[Int(written)] = 0
        return String(cString: buf)
    }
}
