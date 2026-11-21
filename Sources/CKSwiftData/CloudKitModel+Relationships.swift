import CloudKit

public extension CloudKitModel {
    @_disfavoredOverload
    @inlinable
    func getValue<Value>(forKey keyPath: KeyPath<Self, Value?>) -> Value?
        where Value: CloudKitModel
    {
        persistentBackingData.getValue(forKey: keyPath)
    }

    @_disfavoredOverload
    @inlinable
    func getValue<Value, OtherModel>(forKey keyPath: KeyPath<Self, Value>) -> Value
        where Value: RelationshipCollection, OtherModel == Value.PersistentElement
    {
        persistentBackingData.getValue(forKey: keyPath)
    }

    @_disfavoredOverload
    @inlinable
    func setValue<Value>(forKey keyPath: KeyPath<Self, Value?>, to newValue: Value?)
        where Value: CloudKitModel
    {
        persistentBackingData.setValue(forKey: keyPath, to: newValue)
    }

    @_disfavoredOverload
    @inlinable
    func setValue<Value, OtherModel>(forKey keyPath: KeyPath<Self, Value>, to newValue: Value)
        where Value: RelationshipCollection, OtherModel == Value.PersistentElement
    {
        persistentBackingData.setValue(forKey: keyPath, to: newValue)
    }
}
