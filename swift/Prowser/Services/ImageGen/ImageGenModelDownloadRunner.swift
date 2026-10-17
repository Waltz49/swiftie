import AppKit
import Foundation

enum ImageGenModelDownloadError: Error, LocalizedError {
    case environmentNotReady(String)
    case cancelled
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .environmentNotReady(let msg): return msg
        case .cancelled: return "Download cancelled."
        case .downloadFailed(let msg): return msg
        }
    }
}

/// Headless HF model download/delete via imagegen venv Python.
enum ImageGenModelDownloadRunner {
    @MainActor
    static func download(
        entry: ImageGenModelDownloadCatalogEntry,
        config: AppConfig,
        hfToken: String?,
        forceDownload: Bool,
        parentWindow: NSWindow?
    ) async throws {
        let env = try resolveEnvironment(config: config)
        let token = resolvedToken(typed: hfToken)
        if entry.gated, token.isEmpty {
            throw ImageGenModelDownloadError.downloadFailed(
                "This gated model needs a Hugging Face token. Enter one in the HF token field or set HF_TOKEN in your environment."
            )
        }

        let baseLabel = """
        Downloading \(entry.repoID).

        The download runs in the background so Prowser stays responsive. Progress will update below when Hugging Face reports it.

        You can cancel anytime; partial downloads resume later.
        """
        let panel = CancellableProgressPanelController(
            title: "Downloading \(entry.displayName)",
            labelText: baseLabel,
            maximum: 100,
            indeterminate: true
        )
        panel.show()

        defer { panel.close() }
        let cancelRequested = { panel.cancelRequested }

        do {
            try await Task.detached(priority: .userInitiated) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: env.executable)
                proc.arguments = ["-c", Self.downloadPythonScript]
                var procEnv = PythonLocator.processEnvironment(for: env)
                procEnv["PROWSER_DOWNLOAD_REPO"] = entry.repoID
                procEnv["PROWSER_DOWNLOAD_PIPELINE"] = entry.pipelineID
                procEnv["PROWSER_DOWNLOAD_FORCE"] = forceDownload ? "1" : "0"
                if !token.isEmpty {
                    procEnv["HF_TOKEN"] = token
                }
                proc.environment = procEnv

                let stdout = Pipe()
                let stderr = Pipe()
                proc.standardOutput = stdout
                proc.standardError = stderr

                try proc.run()

                let handle = stdout.fileHandleForReading
                var buffer = Data()
                while true {
                    if cancelRequested() {
                        proc.terminate()
                        throw ImageGenModelDownloadError.cancelled
                    }
                    let chunk = try handle.read(upToCount: 4096) ?? Data()
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[..<newline]
                        buffer.removeSubrange(0...newline)
                        if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !line.isEmpty {
                            Self.handleProgressLine(line, panel: panel, baseLabel: baseLabel)
                        }
                    }
                }
                proc.waitUntilExit()
                if cancelRequested() {
                    throw ImageGenModelDownloadError.cancelled
                }
                if proc.terminationStatus != 0 {
                    let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    throw ImageGenModelDownloadError.downloadFailed(
                        errText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000).description
                            .isEmpty ? "Model download failed (exit \(proc.terminationStatus))." : String(errText.prefix(4000))
                    )
                }
            }.value

            ImageGenHFModelLocality.invalidateCache(repoID: entry.repoID, pipelineID: entry.pipelineID)
            if !ImageGenHFModelLocality.modelIsInstalled(entry: entry) {
                throw ImageGenModelDownloadError.downloadFailed(
                    "Download finished but \(entry.repoID) still appears incomplete. "
                        + "Check Hugging Face access (model license) and disk space, then try again."
                )
            }
        } catch let error as ImageGenModelDownloadError {
            throw error
        } catch {
            throw ImageGenModelDownloadError.downloadFailed(String(describing: error).prefix(4000).description)
        }
    }

    @MainActor
    static func deleteFromHFCache(repoID: String, config: AppConfig) async throws -> Bool {
        let env = try resolveEnvironment(config: config)
        return try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: env.executable)
            proc.arguments = [
                "-c",
                """
                import json, os
                from imagegen_plugins.model_download_catalog import delete_model_from_hf_cache
                ok = delete_model_from_hf_cache(os.environ["PROWSER_DELETE_REPO"])
                print(json.dumps({"deleted": ok}))
                """,
            ]
            var procEnv = PythonLocator.processEnvironment(for: env)
            procEnv["PROWSER_DELETE_REPO"] = repoID
            proc.environment = procEnv
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = Pipe()
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return false }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let deleted = json["deleted"] as? Bool else { return false }
            return deleted
        }.value
    }

    @MainActor
    private static func resolveEnvironment(config: AppConfig) throws -> PythonLocator.Environment {
        guard ImageGenPythonBundle.rootURL() != nil else {
            throw ImageGenModelDownloadError.environmentNotReady("Bundled pipeline scripts are missing.")
        }
        guard ImageGenPluginAvailability.venvPythonReady(config: config) else {
            throw ImageGenModelDownloadError.environmentNotReady(
                "huggingface_hub is required to download model weights. "
                    + "Set up the imagegen venv in Settings → Image Generation."
            )
        }
        guard let env = PythonLocator.resolve(profilePath: config.prowserHome.path, config: config) else {
            throw ImageGenModelDownloadError.environmentNotReady("Could not locate imagegen Python.")
        }
        return env
    }

    private static func resolvedToken(typed: String?) -> String {
        let typedTrim = (typed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedTrim.isEmpty { return typedTrim }
        return (ProcessInfo.processInfo.environment["HF_TOKEN"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func handleProgressLine(_ line: String, panel: CancellableProgressPanelController, baseLabel: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["event"] as? String == "progress" else { return }
        let n = (json["n"] as? NSNumber)?.doubleValue ?? 0
        let total = (json["total"] as? NSNumber)?.doubleValue ?? 0
        let desc = json["desc"] as? String ?? ""
        if total > 0 {
            let pct = min(100, max(0, Int(n * 100 / total)))
            var progressLine = "\(formatBytes(n)) / \(formatBytes(total))"
            if !desc.isEmpty, desc != "Downloading (incomplete total...)" {
                progressLine = "\(desc)\n\(progressLine)"
            }
            panel.update(value: pct, label: "\(baseLabel)\n\n\(progressLine)")
        } else if !desc.isEmpty, desc != "Downloading (incomplete total...)" {
            panel.updateStatus(label: "\(baseLabel)\n\n\(desc)")
        }
    }

    private static func formatBytes(_ num: Double) -> String {
        if num <= 0 { return "0 B" }
        if num < 1_000_000 { return String(format: "%.1f KB", num / 1_000) }
        if num < 1_000_000_000 { return String(format: "%.1f MB", num / 1_000_000) }
        return String(format: "%.1f GB", num / 1_000_000_000)
    }

    /// Embedded headless downloader (JSON progress lines on stdout).
    private static let downloadPythonScript = """
    import json, os, sys

    def emit(obj):
        print(json.dumps(obj), flush=True)

    class _Progress:
        # Minimal tqdm stand-in for huggingface_hub.snapshot_download (see model_download_progress.py).

        def __init__(self, *args, **kwargs):
            self.desc = str(kwargs.pop("desc", "") or "")
            self._n = float(kwargs.pop("initial", 0) or 0)
            self._total = float(kwargs.pop("total", 0) or 0)
            self.format_dict = {"rate": None}
            for key in (
                "disable", "name", "log_level", "unit", "unit_scale", "unit_divisor",
                "file", "mininterval", "maxinterval", "miniters", "ascii", "position",
                "leave", "dynamic_ncols", "smoothing", "bar_format",
            ):
                kwargs.pop(key, None)
            self._notify()

        def _notify(self):
            emit({"event": "progress", "n": self._n, "total": self._total, "desc": self.desc})

        @property
        def total(self):
            return self._total

        @total.setter
        def total(self, value):
            self._total = float(value or 0)
            self._notify()

        @property
        def n(self):
            return self._n

        def update(self, n=1):
            if n is None:
                return self._n
            self._n += float(n)
            self._notify()
            return self._n

        def refresh(self):
            self._notify()

        def set_description(self, desc=None, refresh=True):
            self.desc = str(desc or "")
            if refresh:
                self.refresh()

        def set_postfix_str(self, postfix, refresh=False):
            pass

        def set_transfer_postfix_str(self, postfix, refresh=False):
            pass

        def update_transfer(self, n=1):
            pass

        def close(self, *a, **k):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *a):
            pass

    repo_id = os.environ["PROWSER_DOWNLOAD_REPO"]
    pipeline_id = os.environ["PROWSER_DOWNLOAD_PIPELINE"]
    force = os.environ.get("PROWSER_DOWNLOAD_FORCE") == "1"
    token = (os.environ.get("HF_TOKEN") or "").strip()
    if token:
        os.environ["HF_TOKEN"] = token
        try:
            from huggingface_hub import login
            login(token=token, add_to_git_credential=False)
        except Exception:
            pass

    from huggingface_hub import snapshot_download
    from imagegen_plugins.sceneworks_klein_mlx import (
        DEFAULT_MLX_TIER,
        is_sceneworks_klein_mlx_repo,
        tier_allow_patterns,
        resolve_tier_model_path,
    )
    from imagegen_plugins.hf_model_ids import hf_repo_snapshot_allow_patterns
    from imagegen_plugins.image_gen_model_availability import invalidate_model_local_cache

    kwargs = {
        "repo_id": repo_id,
        "force_download": force,
        "tqdm_class": _Progress,
    }
    if is_sceneworks_klein_mlx_repo(repo_id):
        kwargs["allow_patterns"] = tier_allow_patterns(DEFAULT_MLX_TIER)
    else:
        patterns = hf_repo_snapshot_allow_patterns(pipeline_id, repo_id)
        if patterns:
            kwargs["allow_patterns"] = list(patterns)

    path = snapshot_download(**kwargs)
    if is_sceneworks_klein_mlx_repo(repo_id):
        tier_path = resolve_tier_model_path(repo_id, DEFAULT_MLX_TIER)
        if not tier_path:
            raise RuntimeError(f"Download finished but {repo_id} tier still appears incomplete.")
    invalidate_model_local_cache(pipeline_id, repo_id)
    emit({"event": "done", "path": path})
    """
}
