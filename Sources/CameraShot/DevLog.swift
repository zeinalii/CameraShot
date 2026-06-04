import Foundation

enum DevLog {
    static func log(_ category: String, _ message: @autoclosure () -> String) {
        #if DEBUG
        NSLog("[CameraShot][%@] %@", category, message())
        #endif
    }
}
