import Foundation

/// Whether diffusers / bundled pipeline workers can run (profile venv + imports).
@MainActor
enum ImageGenPluginAvailability {
    private static var lastVenvCheck: (path: String, ok: Bool, checked: Date)?
    private static var lastMfluxCheck: (path: String, ok: Bool, checked: Date)?

    static func venvPythonReady(config: AppConfig) -> Bool {
        FileManager.default.isExecutableFile(atPath: config.imagegenVenvPythonPath())
    }

    static func diffusersPipelineReady(config: AppConfig) -> Bool {
        let python = config.imagegenVenvPythonPath()
        if let cached = lastVenvCheck,
           cached.path == python,
           Date().timeIntervalSince(cached.checked) < 120 {
            return cached.ok
        }
        guard FileManager.default.isExecutableFile(atPath: python),
              ImageGenPythonBundle.rootURL() != nil,
              let env = PythonLocator.resolve(profilePath: nil, config: config) else {
            lastVenvCheck = (python, false, Date())
            return false
        }
        let ok = probeImports(environment: env)
        lastVenvCheck = (python, ok, Date())
        return ok
    }

    static func mfluxPipelineReady(config: AppConfig) -> Bool {
        let python = config.imagegenVenvPythonPath()
        if let cached = lastMfluxCheck,
           cached.path == python,
           Date().timeIntervalSince(cached.checked) < 120 {
            return cached.ok
        }
        guard FileManager.default.isExecutableFile(atPath: python),
              ImageGenPythonBundle.rootURL() != nil,
              let env = PythonLocator.resolve(profilePath: nil, config: config) else {
            lastMfluxCheck = (python, false, Date())
            return false
        }
        let ok = probeMfluxImports(environment: env)
        lastMfluxCheck = (python, ok, Date())
        return ok
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

    private static func probeMfluxImports(environment: PythonLocator.Environment) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: environment.executable)
        process.arguments = ["-c", "import mflux; print('ok')"]
        process.environment = PythonLocator.processEnvironment(for: environment)
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

    private static func probeImports(environment: PythonLocator.Environment) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: environment.executable)
        process.arguments = ["-c", "import diffusers, torch, peft, sdnq; print('ok')"]
        process.environment = PythonLocator.processEnvironment(for: environment)
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
