import Foundation
import LlamaSwift

// MARK: - Gemma Backend
//
// LLM backend using Gemma 4 via llama.cpp.
// Reusable across any iOS app that needs on-device LLM inference.
// Handles model loading, prompt formatting (Gemma 4 template), and generation.

public final class GemmaBackend: LLMBackend, @unchecked Sendable {

    // MARK: - State

    private nonisolated(unsafe) var model: OpaquePointer?
    private nonisolated(unsafe) var context: OpaquePointer?
    private nonisolated(unsafe) var sampler: UnsafeMutablePointer<llama_sampler>?
    private let generationLock = NSLock()
    private var _contextSize: Int = 4096
    private var _isReady: Bool = false

    public var isReady: Bool { _isReady }
    public var contextSize: Int { _contextSize }

    // MARK: - Init

    public init() {
        llama_backend_init()
    }

    deinit {
        unload()
        llama_backend_free()
    }

    // MARK: - Load Model

    public func load(modelPath: String, contextSize: Int = 4096, gpuLayers: Int32 = 99) throws {
        unload()

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = gpuLayers

        guard let m = llama_model_load_from_file(modelPath, mparams) else {
            throw GemmaError.loadFailed("Failed to load model from \(modelPath)")
        }

        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(contextSize)
        cparams.n_batch = 512
        cparams.n_threads = 4
        cparams.n_threads_batch = 4

        guard let ctx = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            throw GemmaError.loadFailed("Failed to create context")
        }

        self.model = m
        self.context = ctx
        self._contextSize = contextSize
        self.sampler = createSampler(temperature: 0.7)
        self._isReady = true
    }

    public func unload() {
        if let s = sampler { llama_sampler_free(s); sampler = nil }
        if let c = context { llama_free(c); context = nil }
        if let m = model { llama_model_free(m); model = nil }
        _isReady = false
    }

    // MARK: - LLMBackend

    public func generate(prompt: String, maxTokens: Int, temperature: Float) async -> String {
        var result = ""
        for await token in generateStream(prompt: prompt, maxTokens: maxTokens, temperature: temperature) {
            result += token
        }
        return result
    }

    public func generateStream(prompt: String, maxTokens: Int, temperature: Float) -> AsyncStream<String> {
        let m = self.model
        let ctx = self.context
        let ready = _isReady
        let lock = self.generationLock

        // Recreate sampler with requested temperature
        if let s = self.sampler { llama_sampler_free(s) }
        let smp = createSampler(temperature: temperature)
        self.sampler = smp

        return AsyncStream { continuation in
            guard ready, let m, let ctx, let smp else {
                continuation.finish()
                return
            }

            // Format prompt with Gemma 4 template
            let formatted = formatGemma4Prompt(prompt)

            Thread.detachNewThread {
                lock.lock()
                defer { lock.unlock() }

                let vocab = llama_model_get_vocab(m)

                // Tokenize
                let maxTokenCount = Int32(formatted.utf8.count + 128)
                var tokens = [llama_token](repeating: 0, count: Int(maxTokenCount))
                let nTokens = llama_tokenize(vocab, formatted, Int32(formatted.utf8.count), &tokens, maxTokenCount, false, true)
                guard nTokens > 0 else { continuation.finish(); return }
                tokens = Array(tokens.prefix(Int(nTokens)))

                // Clear KV cache
                let mem = llama_get_memory(ctx)
                llama_memory_clear(mem, true)

                // Process prompt in batches
                var batch = llama_batch_init(512, 0, 1)
                defer { llama_batch_free(batch) }

                var pos: Int32 = 0
                var offset = 0
                while offset < Int(nTokens) {
                    batch.n_tokens = 0
                    let chunkEnd = min(offset + 512, Int(nTokens))
                    for j in offset..<chunkEnd {
                        let isLast = (j == Int(nTokens) - 1)
                        let i = Int(batch.n_tokens)
                        batch.token[i] = tokens[j]
                        batch.pos[i] = pos
                        batch.n_seq_id[i] = 1
                        batch.seq_id[i]![0] = 0
                        batch.logits[i] = isLast ? 1 : 0
                        batch.n_tokens += 1
                        pos += 1
                    }
                    if llama_decode(ctx, batch) != 0 { continuation.finish(); return }
                    offset = chunkEnd
                }

                // Generate
                var generated = 0
                while generated < maxTokens {
                    let newToken = llama_sampler_sample(smp, ctx, batch.n_tokens - 1)
                    if llama_vocab_is_eog(vocab, newToken) { break }

                    var buf = [CChar](repeating: 0, count: 256)
                    let nChars = llama_token_to_piece(vocab, newToken, &buf, 256, 0, false)
                    if nChars > 0 {
                        buf[Int(nChars)] = 0
                        continuation.yield(String(cString: buf))
                    }
                    generated += 1

                    batch.n_tokens = 0
                    batch.token[0] = newToken
                    batch.pos[0] = pos
                    batch.n_seq_id[0] = 1
                    batch.seq_id[0]![0] = 0
                    batch.logits[0] = 1
                    batch.n_tokens = 1
                    pos += 1

                    if llama_decode(ctx, batch) != 0 { break }
                }

                continuation.finish()
            }
        }
    }

    public func countTokens(_ text: String) -> Int {
        guard let m = model else { return text.count / 3 }
        let vocab = llama_model_get_vocab(m)
        let maxTokens = Int32(text.utf8.count + 128)
        var tokens = [llama_token](repeating: 0, count: Int(maxTokens))
        let n = llama_tokenize(vocab, text, Int32(text.utf8.count), &tokens, maxTokens, false, true)
        return n > 0 ? Int(n) : text.count / 3
    }

    // MARK: - Gemma 4 Prompt Template

    private func formatGemma4Prompt(_ rawPrompt: String) -> String {
        // Gemma 4 uses <|turn> (token 105) and <turn|> (token 106)
        return "<bos><|turn>user\n\(rawPrompt)<turn|>\n<|turn>model\n"
    }

    // MARK: - Sampler

    private func createSampler(temperature: Float) -> UnsafeMutablePointer<llama_sampler>? {
        let sparams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(sparams) else { return nil }

        llama_sampler_chain_add(chain, llama_sampler_init_penalties(256, 1.15, 0.0, 0.0))
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))

        return chain
    }
}

// MARK: - Error

public enum GemmaError: LocalizedError {
    case loadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .loadFailed(let msg): return "Gemma load failed: \(msg)"
        }
    }
}
