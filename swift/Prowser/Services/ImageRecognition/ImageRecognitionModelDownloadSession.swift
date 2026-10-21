import Foundation
import Security

/// HTTPS session for search-model downloads. Pins the bundled cert for `waltzremote.com` (self-signed on the default host).
enum ImageRecognitionModelDownloadSession {
    private static let pinnedHost = "waltzremote.com"
    private static let delegate = SessionDelegate()

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3_600
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    /// Progress: bytes written and expected (expected may be `NSURLSessionTransferSizeUnknown` = -1).
    typealias ProgressHandler = @Sendable (Int64, Int64) -> Void

    static func download(
        from url: URL,
        onProgress: ProgressHandler?
    ) async throws -> (URL, URLResponse) {
        try await delegate.download(from: url, session: session, onProgress: onProgress)
    }

    private final class SessionDelegate: NSObject, URLSessionDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
        private lazy var pinnedCertificateData: Data? = {
            guard let url = ProwserResourceBundle.url(forResource: "waltzremote_search_models", withExtension: "cer") else {
                return nil
            }
            return try? Data(contentsOf: url)
        }()

        private let lock = NSLock()
        private var inflight: [Int: InflightDownload] = [:]

        private struct InflightDownload {
            let continuation: CheckedContinuation<(URL, URLResponse), Error>
            let onProgress: ProgressHandler?
            var finishedFileURL: URL?
            var response: URLResponse?
        }

        func download(
            from url: URL,
            session: URLSession,
            onProgress: ProgressHandler?
        ) async throws -> (URL, URLResponse) {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: url)
                lock.lock()
                inflight[task.taskIdentifier] = InflightDownload(
                    continuation: continuation,
                    onProgress: onProgress,
                    finishedFileURL: nil,
                    response: nil
                )
                lock.unlock()
                ActiveModelDownload.shared.registerDownloadTask(task)
                task.resume()
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            lock.lock()
            let handler = inflight[downloadTask.taskIdentifier]?.onProgress
            lock.unlock()
            handler?(totalBytesWritten, totalBytesExpectedToWrite)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("prowser-model-\(UUID().uuidString).zip")
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: location, to: dest)
                lock.lock()
                if var entry = inflight[downloadTask.taskIdentifier] {
                    entry.finishedFileURL = dest
                    entry.response = downloadTask.response
                    inflight[downloadTask.taskIdentifier] = entry
                }
                lock.unlock()
            } catch {
                complete(taskIdentifier: downloadTask.taskIdentifier, result: .failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain, ns.code == URLError.cancelled.rawValue {
                    complete(taskIdentifier: task.taskIdentifier, result: .failure(ModelDownloadError.userDeclined))
                } else {
                    complete(taskIdentifier: task.taskIdentifier, result: .failure(error))
                }
                return
            }
            lock.lock()
            let entry = inflight[task.taskIdentifier]
            lock.unlock()
            guard let entry, let fileURL = entry.finishedFileURL, let response = entry.response else {
                complete(
                    taskIdentifier: task.taskIdentifier,
                    result: .failure(ModelDownloadError.downloadFailed("Empty download response."))
                )
                return
            }
            complete(taskIdentifier: task.taskIdentifier, result: .success((fileURL, response)))
        }

        private func complete(taskIdentifier: Int, result: Result<(URL, URLResponse), Error>) {
            lock.lock()
            let entry = inflight.removeValue(forKey: taskIdentifier)
            lock.unlock()
            ActiveModelDownload.shared.clearDownloadTask()
            guard let entry else { return }
            switch result {
            case .success(let pair):
                entry.continuation.resume(returning: pair)
            case .failure(let error):
                entry.continuation.resume(throwing: error)
            }
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let serverTrust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            let host = challenge.protectionSpace.host.lowercased()
            guard host == ImageRecognitionModelDownloadSession.pinnedHost,
                  let pinnedData = pinnedCertificateData,
                  let pinnedCert = SecCertificateCreateWithData(nil, pinnedData as CFData),
                  let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
                  let serverCert = chain.first else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            let serverData = SecCertificateCopyData(serverCert) as Data
            guard serverData == pinnedData else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            SecTrustSetPolicies(serverTrust, [SecPolicyCreateBasicX509()] as CFArray)
            SecTrustSetAnchorCertificates(serverTrust, [pinnedCert] as CFArray)
            SecTrustSetAnchorCertificatesOnly(serverTrust, true)

            var trustError: CFError?
            if SecTrustEvaluateWithError(serverTrust, &trustError) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
