import Foundation
import CoreFoundation

/// Process-scoped timing request; carries no payload and needs no game file edits.
public enum GameFrameTraceControl {
    public static func name(processID: Int32) -> String {
        "com.zhu.switchviewer.frame-trace.\(processID)"
    }

    public static func request(processID: Int32) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name(processID: processID) as CFString), nil, nil, true)
    }

    public static func observe(processID: Int32, callback: CFNotificationCallback) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil,
            callback, name(processID: processID) as CFString, nil, .deliverImmediately)
    }
}
