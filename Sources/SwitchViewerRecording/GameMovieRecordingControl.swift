import Foundation
import CoreFoundation

public enum GameMovieRecordingControl {
    public static func name(processID: Int32, start: Bool) -> String {
        "com.zhu.switchviewer.comparison-movie.\(start ? "start" : "stop").\(processID)"
    }
    public static func request(processID: Int32, start: Bool) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name(processID: processID, start: start) as CFString), nil, nil, true)
    }
    public static func observe(processID: Int32, start: Bool, callback: CFNotificationCallback) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil,
            callback, name(processID: processID, start: start) as CFString, nil, .deliverImmediately)
    }
}
