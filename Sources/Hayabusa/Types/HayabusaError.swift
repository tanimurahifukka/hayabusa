public enum HayabusaError: Error, CustomStringConvertible {
    case modelLoadFailed(String)
    case vocabLoadFailed
    case contextCreationFailed
    case samplerCreationFailed
    case decodeFailed
    case tokenizationFailed
    case templateFailed
    case noSlotsAvailable
    case contextExceeded
    case remoteNodeFailed
    /// Dispatcher refused to start because the worker registry is missing
    /// at least one Worker for a declared capability jobType.
    case dispatcherWorkerMissing([String])

    public var description: String {
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
        case .remoteNodeFailed: "Remote cluster node failed to respond"
        case .dispatcherWorkerMissing(let jobTypes):
            "dispatcher refused: no Worker registered for jobType(s): \(jobTypes.joined(separator: ", "))"
        }
    }
}
