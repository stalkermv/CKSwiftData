import Foundation

extension CloudRecordValueKind {
    /// The array kind of a declared attribute type such as `[String]` or
    /// `[Int64]?`. Other types return `nil`, because only arrays lose their
    /// element type when they are empty.
    init?(arrayAttributeType type: Any.Type) {
        switch type {
        case is [String].Type, is [String]?.Type:
            self = .stringArray
        case is [Int64].Type, is [Int64]?.Type, is [Int].Type, is [Int]?.Type:
            self = .int64Array
        case is [Double].Type, is [Double]?.Type:
            self = .doubleArray
        case is [Date].Type, is [Date]?.Type:
            self = .dateArray
        default:
            return nil
        }
    }
}
