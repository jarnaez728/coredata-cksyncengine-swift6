//
//  SyncEngine.swift
//  CoreDataCKSyncEngineSwift6
//
//  Created by Javier Arnáez de Pedro on 31/7/25.
//

import Foundation
import CloudKit
import CoreData

fileprivate typealias ChangeToken = CKSyncEngine.State.Serialization

final class SyncEngine {
    // MARK: - Properties
    private let container: CKContainer = CKContainer(identifier: CloudKitConfig.identifier)
    private let defaults: UserDefaults = .standard
    private let syncTokenKey: String = CloudKitConfig.tokenName
    private let context: NSManagedObjectContext
    
    private var _engine: CKSyncEngine?
    private var engine: CKSyncEngine {
        if let existingEngine = _engine {
            return existingEngine
        }
        
        logDebug("☁️ Initializing sync engine.")
        let token: ChangeToken? = fetchCachedSyncToken()
        let syncConfig = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                    stateSerialization: token,
                                                    delegate: self)
        let newEngine = CKSyncEngine(syncConfig)
        _engine = newEngine
        return newEngine
    }
        
    // MARK: - Init
    init(context: NSManagedObjectContext) {
        self.context = context
    }
    
    /*
    private(set) lazy var engine: CKSyncEngine = {
        logDebug("☁️ Initializing sync engine.")
        let token: ChangeToken? = fetchCachedSyncToken()
        let syncConfig = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                    stateSerialization: token,
                                                    delegate: self)
        return .init(syncConfig)
    }()
     */
    
    // MARK: - Sync Token Management
    private func cacheSyncToken(_ token: ChangeToken) {
        do {
            let tokenData = try JSONEncoder().encode(token)
            defaults.set(tokenData, forKey: syncTokenKey)
        } catch {
            logDebug("\(#function) - \(error.localizedDescription)")
        }
    }
    
    private func fetchCachedSyncToken() -> ChangeToken? {
        guard let tokenData: Data = defaults.data(forKey: syncTokenKey) else {
            return nil
        }
        
        do {
            let token = try JSONDecoder().decode(ChangeToken.self, from: tokenData)
            return token
        } catch {
            logDebug("\(#function) - \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - CloudKit Zone/Legacy Management
    func removeOldZoneIfExists() async {
        let oldZoneID = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone")
        logDebug("☁️ [CLEANUP] Removing old CloudKit zone: \(oldZoneID.zoneName)")
        engine.state.add(pendingDatabaseChanges: [ .deleteZone(oldZoneID) ])
    }
    
    private func deleteAllRecords(ofType recordType: String, in database: CKDatabase) async {
        var cursor: CKQueryOperation.Cursor? = nil

        repeat {
            do {
                // 1. Fetch records to delete
                let result: (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?)
                if let currentCursor = cursor {
                    result = try await database.records(continuingMatchFrom: currentCursor)
                } else {
                    let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
                    result = try await database.records(matching: query)
                }
                let recordIDsToDelete = result.matchResults.map { $0.0 }

                // 2. Delete the records if there are any
                if !recordIDsToDelete.isEmpty {
                    do {
                        _ = try await database.modifyRecords(saving: [], deleting: recordIDsToDelete)
                        logDebug("✅ Deleted \(recordIDsToDelete.count) '\(recordType)' records")
                    } catch {
                        logDebug("❌ Error deleting records of type '\(recordType)': \(error)")
                    }
                }

                // 3. Prepare for next batch (pagination)
                cursor = result.queryCursor

            } catch {
                logDebug("❌ Error fetching records of type '\(recordType)': \(error)")
                break
            }
        } while cursor != nil
    }

    func deleteAllLegacyRecords() async {
        logDebug("☁️ [CLEANUP] Removing old CloudKit records:")
        let database = container.privateCloudDatabase
        let legacyRecordTypes = [
            "CD_UserEntity",
            "CD_SwimTimeEntity",
            "CD_SplitTimeEntity"
        ]
        for type in legacyRecordTypes {
            await deleteAllRecords(ofType: type, in: database)
        }
    }
    
    // MARK: - Full Sync/Reset Operations
    func reuploadEverything() async {
        logDebug("☁️ Uploading all data and creating zone.")
        engine.state.add(pendingDatabaseChanges: [ .saveZone(CKRecordZone(zoneName: CloudKitConfig.zoneName)) ])
        await queueAllUsersToCloudKit()
        await queueAllSwimTimesToCloudKit()
    }
    
    func removeAllData() async {
        logDebug("☁️ Removing all data locally and on the server.")
        
        // 1. Recoge todos los IDs de todos los objetos locales
        let allUserIDs: [CKRecord.ID] = await fetchAllUserEntities().compactMap {
            $0.id.map { CKRecord.ID(recordName: $0.uuidString, zoneID: CKRecordZone.ID(zoneName: CloudKitConfig.zoneName)) }
        }
        let allSwimTimeIDs: [CKRecord.ID] = await fetchAllSwimTimeEntities().compactMap {
            $0.id.map { CKRecord.ID(recordName: $0.uuidString, zoneID: CKRecordZone.ID(zoneName: CloudKitConfig.zoneName)) }
        }
        
        // 2. Borra todas las entidades locales
        await removeAllUserEntities()
        await removeAllSwimTimeEntities()
        
        // 3. Marca los registros remotos para eliminación en CloudKit
        let recordRemovals: [CKSyncEngine.PendingRecordZoneChange] =
        (allUserIDs + allSwimTimeIDs).map { .deleteRecord($0) }
        engine.state.add(pendingRecordZoneChanges: recordRemovals)
        
        // 4. Borra la zona de CloudKit si quieres eliminar *todo* en la nube (opcional)
        let zoneID = CKRecordZone.ID(zoneName: CloudKitConfig.zoneName)
        engine.state.add(pendingDatabaseChanges: [ .deleteZone(zoneID) ])
    }
}

extension SyncEngine: CKSyncEngineDelegate {
    // MARK: - CKSyncEngineDelegate
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        logDebug("☁️ sync engine event came in, processing...")
        switch event {
        case .stateUpdate(let stateUpdate):
            logDebug("☁️ Caching sync token.")
            let recentToken = stateUpdate.stateSerialization
            cacheSyncToken(recentToken)
            NotificationCenter.default.post(name: .syncStatusChanged, object: SyncStatus.idle)
        case .accountChange(let accountChange):
            logDebug("☁️ Handling account change.")
            await processAccountChange(accountChange)
        case .fetchedDatabaseChanges(let fetchedDatabaseChanges):
            logDebug("☁️ Processing database changes.")
            await processFetchedDatabaseChanges(fetchedDatabaseChanges)
        case .fetchedRecordZoneChanges(let fetchedRecordZoneChanges):
            logDebug("☁️ Processing record zone changes.")
            await processFetchedRecordZoneChanges(fetchedRecordZoneChanges)
        case .sentRecordZoneChanges(let sentRecordZoneChanges):
            logDebug("☁️ Processing sent record zone changes.")
            processSentRecordZoneChanges(sentRecordZoneChanges)
            // Al empezar la sincronización
        case .willFetchChanges, .willFetchRecordZoneChanges, .willSendChanges:
            logDebug("☁️ Will process changes.")
            NotificationCenter.default.post(name: .syncStatusChanged, object: SyncStatus.syncing)
        // Al finalizar y guardar el estado
        case .didSendChanges,
             .didFetchRecordZoneChanges,
             .didFetchChanges,
             .sentDatabaseChanges:
            // We don't use any of these for our simple example. In the #RealWorld, you might use these to fire
            // Any local logic or data depending on the event.
            logDebug("☁️ Purposely unhandled event came in - \(event)")
            break
        @unknown default:
            logDebug("☁️ Processed unknown CKSyncEngine event: \(event)")
        }
        
        // All sync edits/updates/etc.
        NotificationCenter.default.post(name: .cloudSyncChangesFinished, object: nil)
    }
    
    // Delegate callback signifying CloudKit is ready for our changes, so we send the ones we marked earlier
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        
        // Pre-cargamos todas las entidades locales
        
        let userEntities: [UserEntity] = await fetchAllUserEntities()
        let swimtimesEntities: [SwimTimeEntity] = await fetchAllSwimTimeEntities()
        
        logDebug("☁️ [DEBUG] nextRecordZoneChangeBatch will process \(changes.count) pending changes.")
        for change in changes {
            switch change {
            case .saveRecord(let recordID):
                if let userEntity = userEntities.first(where: { $0.id?.uuidString == recordID.recordName }) {
                    logDebug("☁️ [SYNC] User INSERT/UPDATE: \(userEntity.id?.uuidString ?? "")")
                } else if let swimTimeEntity = swimtimesEntities.first(where: { $0.id?.uuidString == recordID.recordName }) {
                    logDebug("☁️ [SYNC] SwimTime INSERT/UPDATE: \(swimTimeEntity.id?.uuidString ?? "")")
                } else {
                    logDebug("☁️ [SYNC] UNKNOWN INSERT/UPDATE: recordID = \(recordID)")
                }
            case .deleteRecord(let recordID):
                if let userEntity = userEntities.first(where: { $0.id?.uuidString == recordID.recordName }) {
                    logDebug("☁️ [SYNC] User DELETION: \(userEntity.id?.uuidString ?? "")")
                } else if let swimTimeEntity = swimtimesEntities.first(where: { $0.id?.uuidString == recordID.recordName }) {
                    logDebug("☁️ [SYNC] SwimTime DELETION: \(swimTimeEntity.id?.uuidString ?? "")")
                } else {
                    logDebug("☁️ [SYNC] UNKNOWN DELETION: recordID = \(recordID)")
                }
            default:
                logDebug("☁️ [SYNC] OTHER change: \(change)")
            }
        }
        
        let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
          
            if let userEntity = userEntities.first(where: { $0.id?.uuidString == recordID.recordName }) {
                return userEntity.toCKRecord()
            } else if let swimTimeEntity = swimtimesEntities.first(where: { $0.id?.uuidString == recordID.recordName }) {
                return swimTimeEntity.toCKRecord()
            } else {
                syncEngine.state.remove(pendingRecordZoneChanges: [ .saveRecord(recordID) ])
                // Usa cualquier recordType adecuado aquí
                return CKRecord(recordType: CloudKitConfig.userRecordType, recordID: recordID)
            }
        }

        logDebug("☁️ Sending changes via nextRecordZoneChangeBatch with \(batch?.recordsToSave.count ?? 0) saves/edits and \(batch?.recordIDsToDelete.count ?? 0) removals.")
        
        return batch
    }
    
    func countRemoteUsersInCloudKit() async throws -> Int {
        let database = container.privateCloudDatabase
        let query = CKQuery(recordType: CloudKitConfig.userRecordType, predicate: NSPredicate(value: true))
        let result = try await database.records(matching: query)
        logDebug("Hay \(result.matchResults.count) usuarios en la nube ")
        return result.matchResults.count
    }
    
    // SyncEngine.swift
    func countRemoteRecordsInCloudKit(recordType: String) async throws -> Int {
        let database = container.privateCloudDatabase
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        var totalCount = 0
        var cursor: CKQueryOperation.Cursor? = nil

        // First batch
        var result = try await database.records(matching: query)
        totalCount += result.matchResults.count
        cursor = result.queryCursor

        // Loop through remaining pages
        while let nextCursor = cursor {
            result = try await database.records(continuingMatchFrom: nextCursor)
            totalCount += result.matchResults.count
            cursor = result.queryCursor
        }
        return totalCount
    }

}

extension SyncEngine {
    // MARK: - CKSyncEngine Events Processing
    func processAccountChange(_ event: CKSyncEngine.Event.AccountChange) async {
        switch event.changeType {
        case .signIn:
            logDebug("☁️ Uploading everything due to account sign in...")
            await reuploadEverything()
        case .switchAccounts, .signOut:
            logDebug("☁️ Removing all local data due to account changes.")
            await removeAllUserEntities()
            await removeAllSwimTimeEntities()
        @unknown default:
            logDebug("Unhandled account change event: \(event)")
        }
    }
    
    func processFetchedDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) async {
        // A zone deletion means we should delete local data.
        for deletion in changes.deletions {
            switch deletion.zoneID.zoneName {
            case CloudKitConfig.zoneName:
                logDebug("☁️ The Quote zone was deleted, removing all local data.")
                await removeAllUserEntities()
                await removeAllSwimTimeEntities()
            default:
                logDebug("☁️ Received deletion for an unknown zone: \(deletion.zoneID)")
            }
        }
    }
    
    func processFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        var didChangeUsers = false
        var didChangeSwimTimes = false
        
        for modification in changes.modifications {
            let record = modification.record
            let recordType = record.recordType
            let recordID = record.recordID.recordName
            
            switch recordType {
            case CloudKitConfig.userRecordType:
                if let existing = await fetchUserEntity(by: recordID) {
                    // Actualiza existente
                    existing.name = record["name"] as? String
                    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
                    record.encodeSystemFields(with: archiver)
                    existing.systemFields = archiver.encodedData
                } else {
                    // Crea nuevo
                    let _ = UserEntity(record: record, context: context)
                }
                didChangeUsers = true
            case CloudKitConfig.swimTimeRecordType:
                if let existing = await fetchSwimTimeEntity(by: recordID) {
                    existing.date = record["date"] as? Date
                    existing.distance = (record["distance"] as? NSNumber)?.int16Value ?? 0
                    existing.style = record["style"] as? String
                    existing.time = (record["time"] as? NSNumber)?.doubleValue ?? 0
                    if let userIdStr = record["userId"] as? String { existing.userId = UUID(uuidString: userIdStr) }
                    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
                    record.encodeSystemFields(with: archiver)
                    existing.systemFields = archiver.encodedData
                } else {
                    _ = SwimTimeEntity(record: record, context: context)
                }
                didChangeSwimTimes = true
            default:
                logDebug("⚠️ Unknown recordType: \(recordType)")
            }
        }
        
        for deletion in changes.deletions {
            let recordID = deletion.recordID.recordName
            let recordType = deletion.recordType // available in CKSyncEngine
            
            switch recordType {
            case CloudKitConfig.userRecordType:
                if let entity = await fetchUserEntity(by: recordID), !entity.isFault, !entity.isDeleted { context.delete(entity) }
            case CloudKitConfig.swimTimeRecordType:
                if let entity = await fetchSwimTimeEntity(by: recordID), !entity.isFault, !entity.isDeleted { context.delete(entity) }
            default:
                logDebug("⚠️ Deletion for unknown recordType: \(String(describing: recordType))")
            }
        }
        saveContext()
        
        // 🔔 Notifica solo lo que ha cambiado
        if didChangeUsers {
            NotificationCenter.default.post(name: .usersDidChange, object: nil)
        }
        if didChangeSwimTimes {
            NotificationCenter.default.post(name: .swimTimesDidChange, object: nil)
        }
    }

    
    func processSentRecordZoneChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) {
        // Handle any failed record saves.
        changes.failedRecordSaves.forEach {
            logDebug("☁️ failed save error code: \($0.error.code)")
        }
    }
}


extension SyncEngine {
    
    // MARK: - CoreData Helpers: UserEntity
    /*
    func fetchAllUserEntities() -> [UserEntity] {
        let request: NSFetchRequest<UserEntity> = UserEntity.fetchRequest()
        do {
            print("Context concurrency: \(context.concurrencyType == .mainQueueConcurrencyType ? "main" : "background")")
            print("Is main thread: \(Thread.isMainThread)")

            return try context.fetch(request)
        } catch {
            logDebug("Error fetching UserEntities from CoreData: \(error)")
            return []
        }
    }
     */
    func fetchAllUserEntities() async -> [UserEntity] {
        await withCheckedContinuation { continuation in
            context.perform {
                let request: NSFetchRequest<UserEntity> = UserEntity.fetchRequest()
                do {
                    let results = try self.context.fetch(request)
                    continuation.resume(returning: results)
                } catch {
                    logDebug("Error fetching UserEntities from CoreData: \(error)")
                    continuation.resume(returning: [])
                }
            }
        }
    }


    func fetchUserEntity(by recordName: String) async -> UserEntity? {
        await withCheckedContinuation { continuation in
            context.perform {
                guard let uuid = UUID(uuidString: recordName) else {
                    logDebug("Invalid UUID format for UserEntity: \(recordName)")
                    continuation.resume(returning: nil)
                    return
                }
                let request: NSFetchRequest<UserEntity> = UserEntity.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                let result = (try? self.context.fetch(request))?.first
                continuation.resume(returning: result)
            }
        }
    }


    func removeAllUserEntities() async {
        let all = await fetchAllUserEntities()
        for entity in all {
            context.delete(entity)
        }
        saveContext()
    }

    func queueAllUsersToCloudKit() async {
        logDebug("☁️ Queuing all CoreData users to the sync state.")
        let userEntities = await fetchAllUserEntities()
        let recordIDs = userEntities.compactMap { entity in
            entity.id.map { CKRecord.ID(recordName: $0.uuidString, zoneID: CKRecordZone.ID(zoneName: CloudKitConfig.zoneName)) }
        }
        let changes: [CKSyncEngine.PendingRecordZoneChange] = recordIDs.map { .saveRecord($0) }
        engine.state.add(pendingRecordZoneChanges: changes)
    }
    
    func queueUsersToCloudKit(for users: [User]) {
        logDebug("☁️ Queuing selected Users to the sync state: \(users.count) items.")
        let zoneID = CKRecordZone.ID(zoneName: CloudKitConfig.zoneName)
        let recordIDs = users.map { user in
            CKRecord.ID(recordName: user.id.uuidString, zoneID: zoneID)
        }
        let changes: [CKSyncEngine.PendingRecordZoneChange] = recordIDs.map { .saveRecord($0) }
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    func queueUserDeletions(_ ids: [UUID]) {
        logDebug("☁️ Queues User deletions to the sync state (CoreData).")
        let recordIDs = ids.map {
            CKRecord.ID(recordName: $0.uuidString, zoneID: CKRecordZone.ID(zoneName: CloudKitConfig.zoneName))
        }
        let deletions: [CKSyncEngine.PendingRecordZoneChange] = recordIDs.map { .deleteRecord($0) }
        engine.state.add(pendingRecordZoneChanges: deletions)
    }


    // MARK: - CoreData Helpers: SwimTimeEntity
    func fetchAllSwimTimeEntities() async -> [SwimTimeEntity] {
        await withCheckedContinuation { continuation in
            context.perform {
                let request: NSFetchRequest<SwimTimeEntity> = SwimTimeEntity.fetchRequest()
                do {
                    let results = try self.context.fetch(request)
                    continuation.resume(returning: results)
                } catch {
                    logDebug("Error fetching SwimTimeEntities from CoreData: \(error)")
                    continuation.resume(returning: [])
                }
            }
        }
    }

    func fetchSwimTimeEntity(by recordName: String) async -> SwimTimeEntity? {
        await withCheckedContinuation { continuation in
        context.perform {
            guard let uuid = UUID(uuidString: recordName) else {
                logDebug("Invalid UUID format for SwimTimeEntity: \(recordName)")
                continuation.resume(returning: nil)
                return
            }
            let request: NSFetchRequest<SwimTimeEntity> = SwimTimeEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            let result = (try? self.context.fetch(request))?.first
            continuation.resume(returning: result)
        }
    }
    }

    func removeAllSwimTimeEntities() async {
        let all = await fetchAllSwimTimeEntities()
        await context.perform {
            for entity in all {
                self.context.delete(entity)
            }
            self.saveContext()
        }
    }

    func queueAllSwimTimesToCloudKit() async {
        logDebug("☁️ Queuing all CoreData swimtimes to the sync state.")
        let swimTimeEntities = await fetchAllSwimTimeEntities()
        let recordIDs = swimTimeEntities.compactMap { entity in
            entity.id.map { CKRecord.ID(recordName: $0.uuidString, zoneID: CKRecordZone.ID(zoneName: CloudKitConfig.zoneName)) }
        }
        let changes: [CKSyncEngine.PendingRecordZoneChange] = recordIDs.map { .saveRecord($0) }
        engine.state.add(pendingRecordZoneChanges: changes)
    }
    
    func queueSwimTimesToCloudKit(for swimTimes: [SwimTime]) {
        logDebug("☁️ Queuing selected SwimTimes to the sync state: \(swimTimes.count) items.")
        let zoneID = CKRecordZone.ID(zoneName: CloudKitConfig.zoneName)
        let recordIDs = swimTimes.map { swimTime in
            CKRecord.ID(recordName: swimTime.id.uuidString, zoneID: zoneID)
        }
        let changes: [CKSyncEngine.PendingRecordZoneChange] = recordIDs.map { .saveRecord($0) }
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    func queueSwimTimeDeletions(_ ids: [UUID]) {
        logDebug("☁️ Queues SwimTime deletions to the sync state (CoreData).")
        let recordIDs = ids.map {
            CKRecord.ID(recordName: $0.uuidString, zoneID: CKRecordZone.ID(zoneName: CloudKitConfig.zoneName))
        }
        let deletions: [CKSyncEngine.PendingRecordZoneChange] = recordIDs.map { .deleteRecord($0) }
        engine.state.add(pendingRecordZoneChanges: deletions)
    }

    // MARK: - General CoreData
    func saveContext() {
        context.perform {
            do {
                if self.context.hasChanges {
                    try self.context.save()
                }
            } catch {
                logDebug("Error saving CoreData: \(error)")
            }
        }
    }
}


extension NSNotification.Name {
    static let syncStatusChanged = NSNotification.Name("syncStatusChanged")
    static let usersDidChange = NSNotification.Name("usersDidChange")
    static let swimTimesDidChange = NSNotification.Name("swimTimesDidChange")
    
    static let removePublishedQuotes: NSNotification.Name = .init(rawValue: "removePublishedQuotes")
    static let cloudSyncChangesFinished: NSNotification.Name = .init(rawValue: "cloudSyncChangesFinished")
}


enum CloudKitConfig {
    static let identifier = "iCloud.jarnaez.CoreDataCKEngine"
    static let userRecordType = "UserTest"
    static let swimTimeRecordType = "SwimTimeTest"
    
    static let zoneName = "CoreDataCKEngineZone"
    static let tokenName = "syncTokenKey"
}

enum SyncStatus: String {
    case idle = "Synced"
    case syncing = "Syncing..."
    case error = "Error"
    case initialSyncing = "Initial syncing..."
}

func logDebug(
    _ message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
) {
    #if DEBUG
    let filename = (file as NSString).lastPathComponent
    //print("[JARNAEZ_DEBUG][\(filename):\(line)] \(function) - \(message)")
    print("[JARNAEZ_DEBUG][\(filename):\(line)] \(message)")
    #endif
}
