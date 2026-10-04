import Foundation
import CoreFoundation

/// Process-scoped toggle. The game acknowledges its actual state in the log.
public enum GameInterpolationControl {
    public static func name(processID: Int32) -> String {
        "com.zhu.switchviewer.interpolation-toggle.\(processID)"
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
