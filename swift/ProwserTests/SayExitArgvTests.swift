import XCTest
@testable import Prowser

final class SayExitArgvTests: XCTestCase {
    private var priorSayExitEnv: String?
    private var priorSayVoiceEnv: String?

    override func tearDown() {
        if let priorSayExitEnv {
            setenv(ExitScriptUtils.envSayExit, priorSayExitEnv, 1)
        } else {
            unsetenv(ExitScriptUtils.envSayExit)
        }
        if let priorSayVoiceEnv {
            setenv(ExitScriptUtils.envSayVoice, priorSayVoiceEnv, 1)
        } else {
            unsetenv(ExitScriptUtils.envSayVoice)
        }
        super.tearDown()
    }

    func testBuildSayExitArgvAppendsPrompt() {
        let raw = "/bin/echo"
        let argv = ExitScriptUtils.buildSayExitArgv(raw: raw, promptText: "hello")
        XCTAssertEqual(argv.first, "/bin/echo")
        XCTAssertEqual(argv.suffix(2), ["-p", "hello"])
    }

    func testBuildSayExitArgvInjectsVoiceWhenUnsetInArgv() {
        priorSayVoiceEnv = getenv(ExitScriptUtils.envSayVoice).map { String(cString: $0) }
        setenv(ExitScriptUtils.envSayVoice, "Joe", 1)
        defer { unsetenv(ExitScriptUtils.envSayVoice) }

        let argv = ExitScriptUtils.buildSayExitArgv(raw: "/bin/echo", promptText: "x")
        XCTAssertTrue(argv.contains("-v"))
        XCTAssertTrue(argv.contains("Joe"))
        XCTAssertEqual(argv.last, "x")
        XCTAssertEqual(argv[argv.count - 2], "-p")
    }

    func testBuildSayExitArgvSkipsVoiceWhenArgvAlreadyHasVoice() {
        priorSayVoiceEnv = getenv(ExitScriptUtils.envSayVoice).map { String(cString: $0) }
        setenv(ExitScriptUtils.envSayVoice, "Joe", 1)
        defer { unsetenv(ExitScriptUtils.envSayVoice) }

        let argv = ExitScriptUtils.buildSayExitArgv(raw: "/bin/echo --voice Sam", promptText: "hi")
        let voiceCount = argv.filter { $0 == "-v" || $0 == "--voice" }.count
        XCTAssertEqual(voiceCount, 1)
        XCTAssertFalse(argv.contains("Joe"))
    }

    @MainActor
    func testResolvedSayExitFallsBackToEnvironment() {
        let config = ProwserTestSupport.ephemeralAppConfig()
        config.loadSettings()
        config.setValue("", forKey: ExitScriptUtils.settingSayExit)

        priorSayExitEnv = getenv(ExitScriptUtils.envSayExit).map { String(cString: $0) }
        setenv(ExitScriptUtils.envSayExit, "/bin/echo", 1)
        defer {
            if let priorSayExitEnv {
                setenv(ExitScriptUtils.envSayExit, priorSayExitEnv, 1)
            } else {
                unsetenv(ExitScriptUtils.envSayExit)
            }
        }

        XCTAssertEqual(ExitScriptUtils.resolvedSayExitCommandRaw(config: config), "/bin/echo")
    }

    func testTextForSpeechStripsAsterisks() {
        XCTAssertEqual(ExitScriptUtils.textForSpeech(" *hello* "), "hello")
    }

    func testExitScriptProcessEnvironmentSetsProwserTmpDir() {
        let scratch = "/tmp/prowser-exit-test"
        let env = ExitScriptUtils.exitScriptProcessEnvironment(scriptPath: "/bin/echo", tmpDir: scratch)
        XCTAssertEqual(env[ExitScriptUtils.envTmpDir], scratch)
    }

    @MainActor
    func testNormalizeExitScriptPreservesTrailingArgs() {
        let raw = "/bin/echo -v semaine"
        let display = SettingsPathValidation.normalizedExitScriptCommandDisplay(raw)
        XCTAssertTrue(display.contains("-v"))
        XCTAssertTrue(display.contains("semaine"))
        let stored = SettingsPathValidation.normalizedStoredExitScriptCommand(raw)
        XCTAssertTrue(stored.contains("-v"))
        XCTAssertTrue(stored.contains("semaine"))
    }
}
