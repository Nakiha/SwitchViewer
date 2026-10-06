import AppKit
import SwitchViewerRecording

extension AppDelegate {
    func toggleComparisonRecording() {
        if gameInjectionController.isGameRunning { gameInjectionController.toggleComparisonRecording(); return }
        if comparisonRecorder.isBusy { comparisonRecorder.stop(); return }
        guard hasSelectedSource, frameInterpolationEnabled else {
            comparisonRecordingStatus = "请先启动画面并开启插帧"; return
        }
        comparisonRecorder.start()
    }
    func revealComparisonRecording() {
        let url = gameInjectionController.isGameRunning || gameInjectionController.canRetryRecordingArchive
            ? gameInjectionController.comparisonRecordingDirectory : comparisonRecordingDirectory
        if let url { NSWorkspace.shared.open(url) }
    }
    func receiveComparisonRecordingEvent(_ event: ComparisonMovieRecorder.Event) {
        switch event {
        case .started(let url):
            comparisonRecordingDirectory = url
            comparisonRecordingStatus = "正在录制两路素材 · 最长 30 秒"
        case .finishing: comparisonRecordingStatus = "正在保存…"
        case .finished(let url):
            comparisonRecordingDirectory = url
            comparisonRecordingStatus = "两路素材已保存"
        case .failed(let message): comparisonRecordingStatus = "录制失败：\(message)"
        }
        gameInjectionController.refreshConfiguration()
        if waitingForRecordingTermination {
            switch event {
            case .finished, .failed:
                finishRecordingTerminationIfReady()
            default: break
            }
        }
    }
    func finishRecordingTerminationIfReady() {
        guard waitingForRecordingTermination, !comparisonRecorder.isBusy,
              !gameInjectionController.comparisonRecordingBusy else { return }
        waitingForRecordingTermination = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
