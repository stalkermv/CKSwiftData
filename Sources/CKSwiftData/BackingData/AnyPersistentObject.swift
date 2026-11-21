import CloudKit

struct AnyCloudKitModel: Hashable {
    let boxed: Any
    let recordID: CKRecord.ID

    init(boxed: Any, recordID: CKRecord.ID) {
        self.boxed = boxed
        self.recordID = recordID
    }

    init<T: CloudKitModel>(_ cloudKitModel: T) {
        boxed = cloudKitModel
        recordID = cloudKitModel.recordID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(recordID)
    }

    static func == (lhs: AnyCloudKitModel, rhs: AnyCloudKitModel) -> Bool {
        lhs.recordID == rhs.recordID
    }
}

struct WeakAnyCloudKitModel: Hashable {
    weak var boxed: AnyObject?
    var recordID: CKRecord.ID

    init(boxed: AnyObject?, recordID: CKRecord.ID) {
        self.boxed = boxed
        self.recordID = recordID
    }

    init<T: CloudKitModel>(_ cloudKitModel: T) {
        boxed = cloudKitModel
        recordID = cloudKitModel.recordID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(recordID)
    }

    static func == (lhs: WeakAnyCloudKitModel, rhs: WeakAnyCloudKitModel) -> Bool {
        lhs.recordID == rhs.recordID
    }
}
