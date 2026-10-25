import Foundation

/// Whether diffusers / bundled pipeline workers can run (profile venv + imports).
@MainActor
enum ImageGenPluginAvailability {
    private static let cacheTTL: TimeInterval = 120

    private static var lastVenvCheck: (path: String, ok: Bool, checked: Date)?
    private static var lastMfluxCheck: (path: String, ok: Bool, checked: Date)?

    private static var diffusersProbeTask: Task<Bool, Never>?
    private static var mfluxProbeTask: Task<Bool, Never>?

    private struct DetachedProbeEnvironment: Sendable {
        let executable: String
        let processEnvironment: [String: String]
    }

    static func venvPythonReady(config: AppConfig) -> Bool {
        FileManager.default.isExecutableFile(atPath: config.imagegenVenvPythonPath())
    }

    /// Call when imagegen venv / profile settings change (registry `reloadSettings`).
    static func invalidateCachedRuntimeProbes() {
        lastVenvCheck = nil
        lastMfluxCheck = nil
        diffusersProbeTask?.cancel()
        diffusersProbeTask = nil
        mfluxProbeTask?.cancel()
        mfluxProbeTask = nil
    }

    /// Cached or optimistic (venv executable only); never blocks on subprocess import probes.
    static func diffusersPipelineReady(config: AppConfig) -> Bool {
        let python = config.imagegenVenvPythonPath()
        if let cached = lastVenvCheck,
           cached.path == python,
           Date().timeIntervalSince(cached.checked) < cacheTTL {
            return cached.ok
        }
        return venvPythonReady(config: config)
    }

    /// Cached or optimistic; never blocks on subprocess import probes.
    static func mfluxPipelineReady(config: AppConfig) -> Bool {
        let python = config.imagegenVenvPythonPath()
        if let cached = lastMfluxCheck,
           cached.path == python,
           Date().timeIntervalSince(cached.checked) < cacheTTL {
            return cached.ok
        }
        return venvPythonReady(config: config)
    }

    static func optimizedPipelineReady(pipelineID: String, config: AppConfig) -> Bool {
        if ImageGenPipelineRouting.diffusersPipelineIDs.contains(pipelineID) {
            return diffusersPipelineReady(config: config)
        }
        if MfluxCLIPipeline.isSupported(pipelineID: pipelineID) {
            return mfluxPipelineReady(config: config)
        }
        return venvPythonReady(config: config)
    }

    /// Run import probes off the main thread (coalesced). Safe to call before `.full` plugin assembly.
    static func ensureFullRuntimeProbes(config: AppConfig) async {
        async let diffusers = ensureDiffusersRuntimeReady(config: config)
        async let mflux = ensureMfluxRuntimeReady(config: config)
        _ = await (diffusers, mflux)
    }

    static func ensureDiffusersRuntimeReady(config: AppConfig) async -> Bool {
        let python = config.imagegenVenvPythonPath()
        if let cached = lastVenvCheck,
           cached.path == python,
           Date().timeIntervalSince(cached.checked) < cacheTTL {
            return cached.ok
        }
        if let diffusersProbeTask {
            return await diffusersProbeTask.value
        }
        guard FileManager.default.isExecutableFile(atPath: python),
              ImageGenPythonBundle.rootURL() != nil,
              let env = PythonLocator.resolve(profilePath: nil, config: config) else {
            lastVenvCheck = (python, false, Date())
            return false
        }
        let detached = DetachedProbeEnvironment(
            executable: env.executable,
            processEnvironment: PythonLocator.processEnvironment(for: env)
        )
        let task = Task.detached {
            runImportsProbe(environment: detached, importMflux: false)
        }
        diffusersProbeTask = task
        let ok = await task.value
        diffusersProbeTask = nil
        lastVenvCheck = (python, ok, Date())
        return ok
    }

    static func ensureMfluxRuntimeReady(config: AppConfig) async -> Bool {
        let python = config.imagegenVenvPythonPath()
        if let cached = lastMfluxCheck,
           cached.path == python,
           Date().timeIntervalSince(cached.checked) < cacheTTL {
            return cached.ok
        }
        if let mfluxProbeTask {
            return await mfluxProbeTask.value
        }
        guard FileManager.default.isExecutableFile(atPath: python),
              ImageGenPythonBundle.rootURL() != nil,
              let env = PythonLocator.resolve(profilePath: nil, config: config) else {
            lastMfluxCheck = (python, false, Date())
            return false
        }
        let detached = DetachedProbeEnvironment(
            executable: env.executable,
            processEnvironment: PythonLocator.processEnvironment(for: env)
        )
        let task = Task.detached {
            runImportsProbe(environment: detached, importMflux: true)
        }
        mfluxProbeTask = task
        let ok = await task.value
        mfluxProbeTask = nil
        lastMfluxCheck = (python, ok, Date())
        return ok
    }

    private nonisolated static func runImportsProbe(
        environment: DetachedProbeEnvironment,
        importMflux: Bool
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: environment.executable)
        if importMflux {
            process.arguments = ["-c", "import mflux; print('ok')"]
        } else {
            process.arguments = ["-c", "import diffusers, torch, peft, sdnq; print('ok')"]
        }
        process.environment = environment.processEnvironment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
