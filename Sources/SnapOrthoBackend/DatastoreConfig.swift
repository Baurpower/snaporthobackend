import Vapor

enum RDSMode: String, Sendable {
    case disabled
    case fallback
    case legacy
}

struct DatastoreConfig: Sendable {
    let supabaseConfigured: Bool
    let rdsConfigured: Bool
    let rdsMode: RDSMode
}

struct DatastoreConfigStorageKey: StorageKey {
    typealias Value = DatastoreConfig
}

extension Application {
    var datastoreConfig: DatastoreConfig {
        storage[DatastoreConfigStorageKey.self]
            ?? DatastoreConfig(supabaseConfigured: false, rdsConfigured: false, rdsMode: .disabled)
    }

    var rdsAvailable: Bool {
        datastoreConfig.rdsConfigured && databases.ids().contains(.psql)
    }
}