enum HayabusaError: Error, CustomStringConvertible {
    case modelLoadFailed(String)
    case vocabLoadFailed
    case contextCreationFailed
    case samplerCreationFailed
    case decodeFailed
    case tokenizationFailed
    case templateFailed
    case noSlotsAvailable
    case contextExceeded

    var description: String {
        switch self {
        case .modelLoadFailed(let path): "Failed to load model: \(path)"
        case .vocabLoadFailed: "Failed to get vocabulary"
        case .contextCreationFailed: "Failed to create context"
        case .samplerCreationFailed: "Failed to create sampler"
        case .decodeFailed: "llama_decode failed"
        case .tokenizationFailed: "Tokenization failed"
        case .templateFailed: "Chat template application failed"
        case .noSlotsAvailable: "All KV cache slots are occupied"
        case .contextExceeded: "Prompt + max_tokens exceeds slot context size"
        }
    }
}
