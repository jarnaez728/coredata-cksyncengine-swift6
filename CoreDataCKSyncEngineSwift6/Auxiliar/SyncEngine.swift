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

/// A thin wrapper around `CKSyncEngine` that orchestrates CloudKit <-> Core Data
/// synchronization for a custom private zone. It:
/// - sets up the sync engine and caches the state token
/// - debounces outbound sends to avoid chatty writes
/// - translates CloudKit events into Core Data mutations
/// - publishes notifications so the UI can react to sync progress
final class SyncEngine: @unchecked Sendable {
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
    
    deinit {
        debounceTask?.cancel()   // Cancel any pending debounce task if still running
    }
    
    // MARK: - Send Orchestration / Debounce
    private var debounceTask: Task<Void, Never>?

    private func scheduleDebouncedSend(after seconds: Double = 1.0) {
        debounceTask?.cancel()
        debounceTask = Task.detached { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            await self?.refreshDataFromLocal() // Trigger sendChanges outside original callback
        }
    }
    
    private let zoneID = CKRecordZone.ID(zoneName: CloudKitConfig.zoneName)
    
    // MARK: - Manual sync triggers
    /// Sends any pending local Core Data changes to CloudKit using the configured scope.
    /// This is the debounced entry-point used across the engine to push changes.
    func refreshDataFromLocal() async{
        do {
              try await engine.sendChanges(
                  CKSyncEngine.SendChangesOptions(scope: .all)
              )
          } catch {
              logDebug("Failed to send changes: \(error)")
          }
    }
    
    /// Fetches remote changes from CloudKit and applies them to Core Data.
    /// Useful on first launch or when you need a manual pull-to-refresh.
    func refreshDataFromCloud() async {
        logDebug("Refresco from la nube")
        do {
            try await engine.fetchChanges(CKSyncEngine.FetchChangesOptions(scope: .all))
            logDebug(" Data synced from CloudKit to Core Data")
        } catch {
            logDebug(" Failed to receive changes: \(error)")
        }
    }
    
    // MARK: - Zone bootstrap
    /// Ensures the custom record zone exists in the private database by enqueueing a `.saveZone` change.
    /// The actual write is performed by the debounced sender.
    func ensureZoneExists() {
        let zone = CKRecordZone(zoneName: CloudKitConfig.zoneName)
        engine.state.add(pendingDatabaseChanges: [.saveZone(zone)])
        scheduleDebouncedSend(after: 0.2)   // Nudge the engine to create the zone
    }

    
    // MARK: - Sync Token Management
    /// Persists the sync engine's serialized state to UserDefaults so the engine can resume efficiently.
    private func cacheSyncToken(_ token: ChangeToken) {
        do {
            let tokenData = try JSONEncoder().encode(token)
            defaults.set(tokenData, forKey: syncTokenKey)
        } catch {
            logDebug("\(#function) - \(error.localizedDescription)")
        }
    }
    
    /// Restores the previously cached engine state from UserDefaults, clearing it if it is corrupted.
    private func fetchCachedSyncToken() -> ChangeToken? {
        guard let data = defaults.data(forKey: syncTokenKey) else { return nil }
        do { return try JSONDecoder().decode(ChangeToken.self, from: data) }
        catch {
            logDebug("\(#function) - token corrupt, clearing. \(error.localizedDescription)")
            defaults.removeObject(forKey: syncTokenKey)
            return nil
        }
    }
    
    /// Deletes *all* records of a record type from the given database, paginating through results.
    /// Intended for maintenance/reset scenarios; not used during normal sync.
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
    
    // MARK: - Full Sync/Reset Operations
    /// Recreates the zone if needed and enqueues *all* local entities for upload.
    /// Useful after account sign-in or when you want to force a full re-upload.
    func reuploadEverything() async {
        logDebug("☁️ Uploading all data and creating zone.")
        engine.state.add(pendingDatabaseChanges: [ .saveZone(CKRecordZone(zoneName: CloudKitConfig.zoneName)) ])
        await queueAllUsersToCloudKit()
        await queueAllSwimTimesToCloudKit()
        
        scheduleDebouncedSend()
    }
    
    /// Removes all local objects and enqueues deletions for all corresponding CloudKit records.
    /// Also schedules a zone deletion and clears the persisted sync token.
    func removeAllData() async {
        logDebug("☁️ Removing all data locally and on the server.")
        
        // 1) Collect all local record IDs
        let allUserIDs       = await fetchRecordIDs(UserEntity.fetchRequest(),       idKeyPath: \.id)
        let allSwimTimeIDs   = await fetchRecordIDs(SwimTimeEntity.fetchRequest(),   idKeyPath: \.id)
        
        
        // 2) Delete all local Core Data entities
        await removeAllUserEntities()
        await removeAllSwimTimeEntities()
        
        // 3) Enqueue deletions for the corresponding CloudKit records
        let recordRemovals: [CKSyncEngine.PendingRecordZoneChange] =
        (allUserIDs + allSwimTimeIDs).map { .deleteRecord($0) }
        engine.state.add(pendingRecordZoneChanges: recordRemovals)
        
        // 4) Optionally delete the entire custom zone in CloudKit
        engine.state.add(pendingDatabaseChanges: [ .deleteZone(zoneID) ])
        
        defaults.removeObject(forKey: syncTokenKey)
        
        scheduleDebouncedSend(after: 0.5)
    }
}

extension SyncEngine: CKSyncEngineDelegate {
    // MARK: - CKSyncEngineDelegate
    /// Main event handler for `CKSyncEngine`. Translates engine callbacks into Core Data updates,
    /// state token caching, and UI notifications.
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        logDebug("☁️ sync engine event came in, processing...")
        switch event {
        case .stateUpdate(let stateUpdate):
            logDebug("☁️ Caching sync token.")
            let recentToken = stateUpdate.stateSerialization
            cacheSyncToken(recentToken)
            postOnMain(.syncStatusChanged, object: SyncStatus.idle)
        case .accountChange(let accountChange):
            logDebug("☁️ Handling account change.")
            Task.detached { [weak self] in
                await self?.processAccountChange(accountChange)
            }
        case .fetchedDatabaseChanges(let fetchedDatabaseChanges):
            logDebug("☁️ Processing database changes.")
            await processFetchedDatabaseChanges(fetchedDatabaseChanges)
        case .fetchedRecordZoneChanges(let fetchedRecordZoneChanges):
            logDebug("☁️ Processing record zone changes.")
            await processFetchedRecordZoneChanges(fetchedRecordZoneChanges)
        case .sentRecordZoneChanges(let sentRecordZoneChanges):
            logDebug("☁️ Processing sent record zone changes.")
            await processSentRecordZoneChanges(sentRecordZoneChanges)
            // Sync cycle starting
        case .willFetchChanges, .willFetchRecordZoneChanges, .willSendChanges:
            logDebug("☁️ Will process changes.")
            postOnMain(.syncStatusChanged, object: SyncStatus.syncing)
        // Sync cycle finished; propagate notifications
        case .didSendChanges,
             .didFetchRecordZoneChanges,
             .didFetchChanges,
             .sentDatabaseChanges:
            // Inform UI changes have happened
            postOnMain(.cloudSyncChangesFinished)
            break
        @unknown default:
            logDebug("☁️ Processed unknown CKSyncEngine event: \(event)")
        }
    }
    
    // Delegate callback signifying CloudKit is ready for our changes, so we send the ones we marked earlier
    /// Supplies the next batch of record-zone changes to the engine. We:
    /// 1) filter pending changes for the current scope
    /// 2) build CKRecord snapshots only for the needed IDs
    /// 3) drop `.saveRecord` items that have no local data (safety)
    /// 4) return a `RecordZoneChangeBatch` whose closure reliably resolves records to save
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        // 1) Take only the changes within the requested scope
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !changes.isEmpty else { return nil }

        // 2) Extract the involved recordNames (saves & deletes)
        let idsNeeded = Set(changes.compactMap { change -> String? in
            switch change {
            case .saveRecord(let id), .deleteRecord(let id): return id.recordName
            default: return nil
            }
        })

        // Convert into UUID just once
        let uuidsNeeded: [UUID] = idsNeeded.compactMap(UUID.init(uuidString:))

        // 3) Build snapshots *only* for the needed objects (inside a context.perform)
        let snapshots = await self.context.perform { () -> (
            user: [String: CKRecord],
            swimTime: [String: CKRecord]
        ) in
            func applyIDPredicate<T: NSManagedObject>(_ req: NSFetchRequest<T>) {
                req.predicate = NSPredicate(format: "id IN %@", uuidsNeeded)
            }

            let uReq: NSFetchRequest<UserEntity> = UserEntity.fetchRequest()
            applyIDPredicate(uReq)
            let users = (try? self.context.fetch(uReq)) ?? []

            let stReq: NSFetchRequest<SwimTimeEntity> = SwimTimeEntity.fetchRequest()
            applyIDPredicate(stReq)
            let swimTimes = (try? self.context.fetch(stReq)) ?? []


            func dict<T: NSManagedObject>(_ entities: [T],
                                          id: (T) -> UUID?,
                                          rec: (T) -> CKRecord) -> [String: CKRecord] {
                Dictionary(uniqueKeysWithValues: entities.compactMap { e in
                    guard let uuid = id(e) else { return nil }
                    return (uuid.uuidString, rec(e))
                })
            }

            return (
                user:     dict(users,     id: { $0.id }, rec: { $0.toCKRecord() }),
                swimTime: dict(swimTimes, id: { $0.id }, rec: { $0.toCKRecord() })
            )
        }

        // 4) Merge into a single map (recordName -> CKRecord)
        let recordMap = snapshots.user
            .merging(snapshots.swimTime) { $1 }
            
        // 5) Logging (avoid touching NSManagedObject instances)
        for change in changes {
            switch change {
            case .saveRecord(let id):
                let name = id.recordName
                switch true {
                case snapshots.user[name] != nil:     logDebug("☁️ [SYNC] User INSERT/UPDATE: \(name)")
                case snapshots.swimTime[name] != nil: logDebug("☁️ [SYNC] SwimTime INSERT/UPDATE: \(name)")
                default:                               logDebug("☁️ [SYNC] UNKNOWN INSERT/UPDATE: \(name)")
                }
            case .deleteRecord(let id):
                let name = id.recordName
                switch true {
                case snapshots.user[name] != nil:     logDebug("☁️ [SYNC] User DELETION: \(name)")
                case snapshots.swimTime[name] != nil: logDebug("☁️ [SYNC] SwimTime DELETION: \(name)")
                default:                               logDebug("☁️ [SYNC] UNKNOWN DELETION: \(name)")
                }
            default:
                break
            }
        }

        // 6) Filter out .saveRecord entries without a CKRecord and remove them from state
        let filteredChanges: [CKSyncEngine.PendingRecordZoneChange] = changes.filter { change in
            guard case let .saveRecord(id) = change else { return true }
            let exists = (recordMap[id.recordName] != nil)
            if !exists {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
                logDebug("⚠️ Removed pending .saveRecord without local data: \(id.recordName)")
            }
            return exists
        }

        guard !filteredChanges.isEmpty else {
            logDebug("☁️ No changes to send after filtering. Skipping batch.")
            return nil
        }

        // 7) Build the batch: the closure will ALWAYS return a valid CKRecord
        let batch = await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: filteredChanges
        ) { [recordMap] recordID in
            guard let rec = recordMap[recordID.recordName] else {
                // Como salvaguarda adicional, retirar por si se coló algo
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            return rec
        }

        logDebug("☁️ Sending changes via nextRecordZoneChangeBatch with \(batch?.recordsToSave.count ?? 0) saves/edits and \(batch?.recordIDsToDelete.count ?? 0) removals.")
        return batch
    }
    
    /// Returns the total number of records for the given type in the private database, paginating through all results.
    func countRemoteRecordsInCloudKit(recordType: String) async throws -> Int {
        let database = container.privateCloudDatabase
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        var totalCount = 0
        var cursor: CKQueryOperation.Cursor? = nil

        // El desiredKeys vacío me trae solo el recordId y el systemfields
        var result = try await database.records(matching: query, desiredKeys: [])
        totalCount += result.matchResults.count
        cursor = result.queryCursor

        // Loop through remaining pages
        while let nextCursor = cursor {
            result = try await database.records(continuingMatchFrom: nextCursor, desiredKeys: [])
            totalCount += result.matchResults.count
            cursor = result.queryCursor
        }
        return totalCount
    }
    
    /// Debug utility: logs how many records exist per record type in the private database.
    func printRemoteCloudKitRecords() async {
        let database = container.privateCloudDatabase
        let recordTypes = [
            CloudKitConfig.userRecordType,
            CloudKitConfig.swimTimeRecordType
        ]

        for recordType in recordTypes {
            let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
            var allRecords: [CKRecord] = []

            do {
                var cursor: CKQueryOperation.Cursor? = nil

                // El desiredkeys vacío me trae solo id y systemfields (más rápido)
                var result = try await database.records(matching: query, desiredKeys: [])
                allRecords += result.matchResults.compactMap { _, result in
                    try? result.get()
                }
                cursor = result.queryCursor

                // Paginación
                while let nextCursor = cursor {
                    result = try await database.records(continuingMatchFrom: nextCursor, desiredKeys: [])
                    allRecords += result.matchResults.compactMap { _, result in
                        try? result.get()
                    }
                    cursor = result.queryCursor
                }

                logDebug("📦 [\(recordType)] there are \(allRecords.count) records on iCloud.")

            } catch {
                logDebug("❌ Error fetching \(recordType) from CloudKit: \(error.localizedDescription)")
            }
        }
    }

}

extension SyncEngine {
    // MARK: - CKSyncEngine Events Processing
    /// Reacts to account changes (sign-in/out/switch). On sign-in, we bootstrap the zone,
    /// pull from CloudKit, and enqueue a full re-upload. On sign-out/switch we clear local data.
    func processAccountChange(_ event: CKSyncEngine.Event.AccountChange) async {
        switch event.changeType {
        case .signIn:
            logDebug("☁️ Uploading everything due to account sign in...")
            ensureZoneExists()
            await refreshDataFromCloud()
            await reuploadEverything()
        case .switchAccounts, .signOut:
            logDebug("☁️ Removing all local data due to account changes.")
            debounceTask?.cancel()
            defaults.removeObject(forKey: syncTokenKey)
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
                logDebug("☁️ The \(CloudKitConfig.zoneName) zone was deleted, removing all local data.")
                defaults.removeObject(forKey: syncTokenKey)
                await removeAllUserEntities()
                await removeAllSwimTimeEntities()
                
                ensureZoneExists()
            default:
                logDebug("☁️ Received deletion for an unknown zone: \(deletion.zoneID)")
            }
        }
    }
    
    /// Applies fetched per-record changes to Core Data within a single `perform` block, then posts UI notifications.
    func processFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) async {

        var didChangeUsers = false
        var didChangeSwimTimes = false
        
        await context.perform {
            // MODIFICATIONS
            for modification in changes.modifications {
                let record = modification.record
                let recordType = record.recordType
                let recordID = record.recordID.recordName

                switch recordType {

                case CloudKitConfig.userRecordType:
                    if let entity = try? self.fetchUserEntitySync(by: recordID) {
                        entity.name      = record["name"] as? String
                        let arch = NSKeyedArchiver(requiringSecureCoding: true)
                        record.encodeSystemFields(with: arch)
                        entity.systemFields = arch.encodedData
                    } else {
                        _ = UserEntity(record: record, context: self.context)
                    }
                    didChangeUsers = true

                case CloudKitConfig.swimTimeRecordType:
                    if let entity = try? self.fetchSwimTimeEntitySync(by: recordID) {
                        entity.date     = record["date"] as? Date
                        entity.distance = (record["distance"] as? NSNumber)?.int32Value ?? 0
                        entity.style    = record["style"] as? String
                        entity.time     = (record["time"] as? NSNumber)?.doubleValue ?? 0
                        if let userIdStr = record["userId"] as? String {
                            entity.userId = UUID(uuidString: userIdStr)
                        }
                        let arch = NSKeyedArchiver(requiringSecureCoding: true)
                        record.encodeSystemFields(with: arch)
                        entity.systemFields = arch.encodedData
                    } else {
                        _ = SwimTimeEntity(record: record, context: self.context)
                    }
                    didChangeSwimTimes = true
                default:
                    logDebug("⚠️ Unknown recordType: \(recordType)")
                }
            }

            // DELETIONS
            for deletion in changes.deletions {
                let recordID = deletion.recordID.recordName
                let recordType = deletion.recordType
                switch recordType {
                case CloudKitConfig.userRecordType:
                    if let e = try? self.fetchUserEntitySync(by: recordID), !e.isFault, !e.isDeleted { self.context.delete(e) }
                case CloudKitConfig.swimTimeRecordType:
                    if let e = try? self.fetchSwimTimeEntitySync(by: recordID), !e.isFault, !e.isDeleted { self.context.delete(e) }
                default:
                    logDebug("⚠️ Deletion for unknown recordType: \(String(describing: recordType))")
                }
            }

            // Persist within the same perform block
            self.saveContextSync()
        }

        // 🔔 Notify OUTSIDE of the perform block
        if didChangeUsers      { postOnMain(.usersDidChange) }
        if didChangeSwimTimes  { postOnMain(.swimTimesDidChange) }
        
    }

    
    /// Handles acknowledgements from CloudKit after sending changes. Updates local systemFields on success
    /// and resolves server-record-changed conflicts by favoring the server version.
    func processSentRecordZoneChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) async {
        
        // ✅ 1) SUCCESS: refresh local systemFields
        if !changes.savedRecords.isEmpty {
            await context.perform {
                for record in changes.savedRecords {
                    let name = record.recordID.recordName
                    let arch = NSKeyedArchiver(requiringSecureCoding: true)
                    record.encodeSystemFields(with: arch)
                    let data = arch.encodedData

                    // Update the corresponding entity if it exists
                    if let e = try? self.fetchUserEntitySync(by: name) {
                        e.systemFields = data
                    } else if let e = try? self.fetchSwimTimeEntitySync(by: name) {
                        e.systemFields = data
                    }
                }
                self.saveContextSync()
            }
        }
        // Handle failed saves
        for failedSave in changes.failedRecordSaves {
            let ckError = failedSave.error
            logDebug("failed save error code: \(ckError.code.rawValue)")
            if ckError.code == .serverRecordChanged, let serverRecord = ckError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                    logDebug(" Conflict detected for record: \(failedSave.record.recordID.recordName)")
                    await self.resolveConflict(localRecord: failedSave.record, serverRecord: serverRecord)
            }
        }
    }
    
    /// Conflict resolution strategy: prefer the server record, update local Core Data fields,
    /// and overwrite `systemFields` with those from the server record.
    private func resolveConflict(localRecord: CKRecord, serverRecord: CKRecord) async {
        let recordType = serverRecord.recordType
        let recordID = serverRecord.recordID.recordName

        await context.perform {
            switch recordType {
            // MARK: User
            case CloudKitConfig.userRecordType:
                if let entity = try? self.fetchUserEntitySync(by: recordID) {
                    entity.name      = serverRecord["name"] as? String
                    
                    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
                    serverRecord.encodeSystemFields(with: archiver)
                    entity.systemFields = archiver.encodedData

                    self.saveContextSync()
                    logDebug("Resolved conflict for User: \(recordID)")
                }

            // MARK: SwimTime
            case CloudKitConfig.swimTimeRecordType:
                if let entity = try? self.fetchSwimTimeEntitySync(by: recordID) {
                    entity.date     = serverRecord["date"] as? Date
                    entity.distance = (serverRecord["distance"] as? NSNumber)?.int32Value ?? 0
                    entity.style    = serverRecord["style"] as? String
                    entity.time     = (serverRecord["time"] as? NSNumber)?.doubleValue ?? 0
                    if let userIdStr = serverRecord["userId"] as? String {
                        entity.userId = UUID(uuidString: userIdStr)
                    }
                    
                    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
                    serverRecord.encodeSystemFields(with: archiver)
                    entity.systemFields = archiver.encodedData

                    self.saveContextSync()
                    logDebug("Resolved conflict for SwimTime: \(recordID)")
                }
            default:
                logDebug("Unknown record type for conflict resolution: \(recordType)")
            }
        }
    }
}


extension SyncEngine {
    
    // MARK: - CoreData Helpers: UserEntity
    /// Helper utilities to fetch, queue, and remove Core Data entities used by the sync engine.
    /// Fetches all UserEntity objects.
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

    /// Fetches a single UserEntity by its CKRecord recordName (UUID string).
    func fetchUserEntity(by recordName: String) async -> UserEntity? {
        await withCheckedContinuation { continuation in
            context.perform {
                guard let uuid = UUID(uuidString: recordName) else {
                    logDebug("Invalid UUID format for UserEntity: \(recordName)")
                    continuation.resume(returning: nil)
                    return
                }
                let request: NSFetchRequest<UserEntity> = UserEntity.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", uuid as (any CVarArg))
                let result = (try? self.context.fetch(request))?.first
                continuation.resume(returning: result)
            }
        }
    }
    
    /// Sync variant used inside context.perform; throws on invalid UUID.
    private func fetchUserEntitySync(by recordName: String) throws -> UserEntity? {
        guard let uuid = UUID(uuidString: recordName) else {
            throw NSError(domain: "Invalid UUID", code: 0)
        }
        let request: NSFetchRequest<UserEntity> = UserEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", uuid as (any CVarArg))
        return try context.fetch(request).first
    }


    /// Deletes every UserEntity and saves the context.
    func removeAllUserEntities() async {
        let all = await fetchAllUserEntities()
        await context.perform {
            for entity in all { self.context.delete(entity) }
            self.saveContextSync()
        }
    }

    /// Enqueues save operations for all users in Core Data.
    func queueAllUsersToCloudKit() async {
        logDebug("☁️ Queuing all CoreData users to the sync state.")
        /*
        let userEntities = await fetchAllUserEntities()
        let recordIDs = userEntities.compactMap { entity in
            entity.id.map { CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID) }
        }
        let changes: [CKSyncEngine.PendingRecordZoneChange] = recordIDs.map { .saveRecord($0) }
        engine.state.add(pendingRecordZoneChanges: changes)
         */
        let ids = await fetchRecordIDs(UserEntity.fetchRequest(), idKeyPath: \.id)
        engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord($0) })
        scheduleDebouncedSend(after: 1.0)
    }
    
    /// Enqueues save operations for a specific set of domain users.
    func queueUsersToCloudKit(for users: [User]) {
        logDebug("☁️ Queuing selected Users to the sync state: \(users.count) items.")
        let recordIDs = users.map { user in
            CKRecord.ID(recordName: user.id.uuidString, zoneID: zoneID)
        }
        let changes: [CKSyncEngine.PendingRecordZoneChange] = recordIDs.map { .saveRecord($0) }
        engine.state.add(pendingRecordZoneChanges: changes)
        scheduleDebouncedSend(after: 1.0)
    }

    /// Enqueues delete operations for the given user IDs.
    func queueUserDeletions(_ ids: [UUID]) {
        logDebug("☁️ Queues User deletions to the sync state (CoreData).")
        let recordIDs = ids.map {
            CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID)
        }
        let deletions: [CKSyncEngine.PendingRecordZoneChange] = recordIDs.map { .deleteRecord($0) }
        engine.state.add(pendingRecordZoneChanges: deletions)
        scheduleDebouncedSend(after: 0.2)
    }


    // MARK: - CoreData Helpers: SwimTimeEntity
    /// Fetches all SwimTimeEntity objects.
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

    /// Fetches a single SwimTimeEntity by its CKRecord recordName (UUID string).
    func fetchSwimTimeEntity(by recordName: String) async -> SwimTimeEntity? {
        await withCheckedContinuation { continuation in
            context.perform {
                guard let uuid = UUID(uuidString: recordName) else {
                    logDebug("Invalid UUID format for SwimTimeEntity: \(recordName)")
                    continuation.resume(returning: nil)
                    return
                }
                let request: NSFetchRequest<SwimTimeEntity> = SwimTimeEntity.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", uuid as (any CVarArg))
                let result = (try? self.context.fetch(request))?.first
                continuation.resume(returning: result)
            }
        }
    }
    
    /// Sync variant used inside context.perform; throws on invalid UUID.
    private func fetchSwimTimeEntitySync(by recordName: String) throws -> SwimTimeEntity? {
        guard let uuid = UUID(uuidString: recordName) else {
            throw NSError(domain: "Invalid UUID", code: 0)
        }
        let request: NSFetchRequest<SwimTimeEntity> = SwimTimeEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", uuid as (any CVarArg))
        return try context.fetch(request).first
    }

    /// Deletes every SwimTimeEntity and saves the context.
    func removeAllSwimTimeEntities() async {
        let all = await fetchAllSwimTimeEntities()
        await context.perform {
            for entity in all {
                self.context.delete(entity)
            }
            self.saveContextSync()
        }
    }

    /// Enqueues save operations for all swim times in Core Data.
    func queueAllSwimTimesToCloudKit() async {
        logDebug("☁️ Queuing all CoreData swimtimes to the sync state.")
        let ids = await fetchRecordIDs(SwimTimeEntity.fetchRequest(), idKeyPath: \.id)
        engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord($0) })
        scheduleDebouncedSend(after: 1.0)
    }
    
    /// Enqueues save operations for a specific set of domain swim times.
    func queueSwimTimesToCloudKit(for swimTimes: [SwimTime]) {
        logDebug("☁️ Queuing selected SwimTimes to the sync state: \(swimTimes.count) items.")
        let recordIDs = swimTimes.map { swimTime in
            CKRecord.ID(recordName: swimTime.id.uuidString, zoneID: zoneID)
        }
        let changes: [CKSyncEngine.PendingRecordZoneChange] = recordIDs.map { .saveRecord($0) }
        engine.state.add(pendingRecordZoneChanges: changes)
        scheduleDebouncedSend(after: 1.0)
    }

    /// Enqueues delete operations for the given swim time IDs.
    func queueSwimTimeDeletions(_ ids: [UUID]) {
        logDebug("☁️ Queues SwimTime deletions to the sync state (CoreData).")
        let recordIDs = ids.map {
            CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID)
        }
        let deletions: [CKSyncEngine.PendingRecordZoneChange] = recordIDs.map { .deleteRecord($0) }
        engine.state.add(pendingRecordZoneChanges: deletions)
        scheduleDebouncedSend(after: 0.2)
    }
    
    // MARK: - General CoreData
    /// Saves the context if there are changes; logs on failure.
    // Only call from within a `context.perform` block
    private func saveContextSync() {
        do {
            if context.hasChanges {
                try context.save()
            }
        } catch {
            logDebug("Error saving context: \(error)")
        }
    }
    
    /// Posts a notification on the main actor without payload.
    private func postOnMain(_ name: Notification.Name) {
        Task { @MainActor in
            NotificationCenter.default.post(name: name, object: nil)
        }
    }

    /// Posts a notification on the main actor with a typed payload.
    private func postOnMain<T: Sendable>(_ name: Notification.Name, object: T?) {
        Task { @MainActor in
            NotificationCenter.default.post(name: name, object: object)
        }
    }
    
    /// Convenience to map Core Data UUIDs to `CKRecord.ID`s for the custom zone.
    private func fetchRecordIDs<T: NSManagedObject>(_ request: NSFetchRequest<T>, idKeyPath: KeyPath<T, UUID?>) async -> [CKRecord.ID] {
        await context.perform {
            let objs = (try? self.context.fetch(request)) ?? []
            return objs.compactMap { obj in
                guard let uuid = obj[keyPath: idKeyPath] else { return nil }
                return CKRecord.ID(recordName: uuid.uuidString, zoneID: self.zoneID)
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

/// Names and identifiers used by the CloudKit integration (container, record types, zone, token key).
enum CloudKitConfig {
    static let identifier = "iCloud.jarnaez.CoreDataCKEngine"
    static let userRecordType = "UserTest"
    static let swimTimeRecordType = "SwimTimeTest"
    
    static let zoneName = "CoreDataCKEngineZone"
    static let tokenName = "syncTokenKey"
}

/// Simple public status used by the UI to display sync progress.
enum SyncStatus: String {
    case idle = "Synced"
    case syncing = "Syncing..."
    case error = "Error"
    case initialSyncing = "Initial syncing..."
}

/// Debug print helper gated by `#if DEBUG`.
func logDebug(
    _ message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
) {
    #if DEBUG
    let filename = (file as NSString).lastPathComponent
    print("[JARNAEZ_DEBUG][\(filename):\(line)] \(message)")
    #endif
}
