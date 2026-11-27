import CoreFoundation
import Foundation

/// Decodes CloudKit's NSNumber-backed scalar values without allowing Swift's
/// numeric bridging to erase the value's original kind. In particular, a
/// `__NSCFBoolean` and an integral `Double` both satisfy `as? Int64` unless
/// the Objective-C number type is inspected first.
enum CloudKitNumberValue {
    static func recordValue(from rawValue: Any) -> CloudRecordValue? {
        guard let number = rawValue as? NSNumber else { return nil }
        switch String(cString: number.objCType) {
        case "c", "B":
            // `objCType == "c"` is also used by NSNumber(Int8), while true
            // booleans are CFBoolean instances. Inspect the CF identity before
            // treating a char-sized number as a flag.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .int64(number.int64Value)
        case "d", "f":
            return .double(number.doubleValue)
        case "q", "Q", "i", "I", "s", "S", "l", "L":
            return .int64(number.int64Value)
        default:
            return nil
        }
    }
}
