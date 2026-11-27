import CloudKit

extension CKRecord {
    /// Reads a field from the encrypted map when the field is encrypted. Values
    /// that arrive in the plain map are still returned, so records written
    /// before the field became encrypted stay readable.
    func storedValue(forKey key: String, encrypted: Bool) -> Any? {
        guard encrypted else { return self[key] }
        return encryptedValues[key] ?? self[key]
    }

    /// Writes a field to the map that matches its encryption option. An
    /// encrypted field also clears the plain map, because CloudKit raises an
    /// exception for a key that exists in both maps, and the encrypted map has
    /// to be cleared first. Plain fields skip the encrypted map on purpose:
    /// touching it on every write is measurably slow.
    func setStoredValue(_ value: CKRecordValueProtocol?, forKey key: String, encrypted: Bool) {
        if encrypted {
            if encryptedValues[key] != nil {
                encryptedValues[key] = nil
            }
            if self[key] != nil {
                self[key] = nil
            }
            encryptedValues[key] = value
        } else {
            self[key] = value
        }
    }
}

extension Schema.PropertyMetadata {
    var isEncryptedAttribute: Bool {
        (metadata as? Schema.Attribute)?.options.contains(.allowsCloudEncryption) == true
    }
}
