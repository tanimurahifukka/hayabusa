import Foundation

@Observable
final class ModelDownloader {
    private(set) var isDownloading = false
    private(set) var progress: Double = 0
    private(set) var currentFile: String = ""
    private(set) var error: String?
    private(set) var totalBytesExpected: Int64 = 0
    private(set) var totalBytesDownloaded: Int64 = 0

    private var downloadTask: URLSessionDownloadTask?
    private var delegateHandler: DownloadDelegate?

    /// Download all files for an MLX model from HuggingFace.
    /// Fetches the file list from the API, then downloads each file sequentially.
    func download(modelId: String, destination: String) {
        guard !isDownloading else { return }
        isDownloading = true
        progress = 0
        error = nil
        currentFile = modelId
        totalBytesExpected = 0
        totalBytesDownloaded = 0

        // Create destination directory
        try? FileManager.default.createDirectory(
            atPath: destination,
            withIntermediateDirectories: true
        )

        Task {
            do {
                let files = try await fetchFileList(modelId: modelId)
                if files.isEmpty {
                    await setError("モデルファイルが見つかりませんでした: \(modelId)")
                    return
                }
                try await downloadFiles(files, modelId: modelId, destination: destination)
                await MainActor.run {
                    self.progress = 1.0
                    self.isDownloading = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isDownloading = false
                }
            } catch {
                await setError(error.localizedDescription)
            }
        }
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
    }

    // MARK: - Private

    @MainActor
    private func setError(_ message: String) {
        self.error = message
        self.isDownloading = false
    }

    /// Fetch the list of files in a HuggingFace repo via API
    private func fetchFileList(modelId: String) async throws -> [HFFile] {
        let urlString = "https://huggingface.co/api/models/\(modelId)"
        guard let url = URL(string: urlString) else {
            throw DownloadError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw DownloadError.apiFailed
        }
        let model = try JSONDecoder().decode(HFModelInfo.self, from: data)
        return model.siblings ?? []
    }

    /// Download files sequentially with progress tracking
    private func downloadFiles(_ files: [HFFile], modelId: String, destination: String) async throws {
        let totalFiles = files.count

        for (index, file) in files.enumerated() {
            try Task.checkCancellation()

            let fileName = file.rfilename
            await MainActor.run {
                self.currentFile = fileName
            }

            let fileURL = "https://huggingface.co/\(modelId)/resolve/main/\(fileName)"
            guard let url = URL(string: fileURL) else { continue }

            let destPath = (destination as NSString).appendingPathComponent(fileName)

            // Create subdirectories if needed
            let destDir = (destPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(
                atPath: destDir,
                withIntermediateDirectories: true
            )

            // Skip if file already exists with correct size
            if let attrs = try? FileManager.default.attributesOfItem(atPath: destPath),
               let existingSize = attrs[.size] as? Int64,
               existingSize > 0 {
                await MainActor.run {
                    self.progress = Double(index + 1) / Double(totalFiles)
                }
                continue
            }

            try await downloadSingleFile(url: url, to: destPath, fileIndex: index, totalFiles: totalFiles)
        }
    }

    private func downloadSingleFile(url: URL, to destPath: String, fileIndex: Int, totalFiles: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = DownloadDelegate(
                destPath: destPath,
                onProgress: { [weak self] fractionCompleted in
                    DispatchQueue.main.async {
                        // Overall progress = (completed files + current file fraction) / total
                        let overallProgress = (Double(fileIndex) + fractionCompleted) / Double(totalFiles)
                        self?.progress = overallProgress
                    }
                },
                onComplete: { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
            self.delegateHandler = delegate

            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            self.downloadTask = task
            task.resume()
        }
    }
}

// MARK: - Models

private struct HFModelInfo: Decodable {
    let siblings: [HFFile]?
}

private struct HFFile: Decodable {
    let rfilename: String
}

private enum DownloadError: LocalizedError {
    case invalidURL
    case apiFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "無効なURLです"
        case .apiFailed: return "HuggingFace APIへの接続に失敗しました"
        }
    }
}

// MARK: - URLSession Download Delegate

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let destPath: String
    let onProgress: (Double) -> Void
    let onComplete: (Error?) -> Void

    init(destPath: String, onProgress: @escaping (Double) -> Void, onComplete: @escaping (Error?) -> Void) {
        self.destPath = destPath
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let destURL = URL(fileURLWithPath: destPath)
            // Remove existing file if present
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: location, to: destURL)
            onComplete(nil)
        } catch {
            onComplete(error)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(fraction)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onComplete(error)
        }
    }
}
