import Foundation
import SwitchViewerInterpolation

/// Parse experiment switches once, outside the per-frame submission path.
struct GameHookConfiguration {
    private let fixture: Bool
    private let arguments: Set<String>
    let cadence: GamePresentationCadence
    let uniformPreparation: Bool
    init(processName: String = ProcessInfo.processInfo.processName, arguments: [String] = CommandLine.arguments,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         runtime: GameRuntimeConfiguration? = nil) {
        fixture = processName == "GameHookFixture"
        self.arguments = Set(arguments)
        cadence = runtime?.cadence ?? .init(configuration: environment["SWITCHVIEWER_GAME_CADENCE"])
        uniformPreparation = cadence == .uniform && (runtime?.displaySync ?? (environment["SWITCHVIEWER_GAME_DISPLAY_SYNC"] != "0")) == false
            && !(fixture && self.arguments.contains("--legacy-preparation-admission"))
    }
    func presentationOptions(syncEnabled: Bool?) -> GameFramePresentationPolicy.Options {
        func enabled(_ flag: String) -> Bool { fixture && arguments.contains(flag) }
        var options = GameFramePresentationPolicy.Options()
        options.immediate = syncEnabled == false && !enabled("--legacy-unsynced-policy")
        options.adaptiveAdmission = options.immediate && !enabled("--unsynced-immediate-only")
        options.minimumCadenceGap = (cadence == .uniform || enabled("--minimum-cadence-gap"))
            && !enabled("--legacy-cadence-gap")
        options.preparationAdmission = uniformPreparation
        options.advanceOriginals = !enabled("--legacy-original-submission")
        options.correctCadence = enabled("--adaptive-unsynced-spacing") && !enabled("--legacy-unsynced-spacing")
        options.strictMidpointDeadline = enabled("--strict-midpoint-deadline")
        options.legacyPairSubmission = enabled("--legacy-pair-submission")
        return options
    }
}
