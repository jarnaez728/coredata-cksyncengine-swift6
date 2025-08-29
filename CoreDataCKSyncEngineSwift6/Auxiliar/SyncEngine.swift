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
        debounceTask?.cancel()   // 👈 Cancelamos si aún sigue viva
    }
    
    // MARK: - Send Orchestration / Debounce
    private var debounceTask: Task<Void, Never>?

    private func scheduleDebouncedSend(after seconds: Double = 1.0) {
        debounceTask?.cancel()
        debounceTask = Task.detached { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            await self?.refreshDataFromLocal() // sendChanges fuera del callback original
        }
    }
    
    private let zoneID = CKRecordZone.ID(zoneName: CloudKitConfig.zoneName)
    
    //MARK: Trigger manual syncing
    func refreshDataFromLocal() async{
        do {
              try await engine.sendChanges(
                  CKSyncEngine.SendChangesOptions(scope: .all)
              )
          } catch {
              logDebug("Failed to send changes: \(error)")
          }
    }
    
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
    func ensureZoneExists() {
        let zone = CKRecordZone(zoneName: CloudKitConfig.zoneName)
        engine.state.add(pendingDatabaseChanges: [.saveZone(zone)])
        scheduleDebouncedSend(after: 0.2)   // empuja la creación de la zona
    }

    
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
        guard let data = defaults.data(forKey: syncTokenKey) else { return nil }
        do { return try JSONDecoder().decode(ChangeToken.self, from: data) }
        catch {
            logDebug("\(#function) - token corrupt, clearing. \(error.localizedDescription)")
            defaults.removeObject(forKey: syncTokenKey)
            return nil
        }
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
    
    // MARK: - Full Sync/Reset Operations
    func reuploadEverything() async {
        logDebug("☁️ Uploading all data and creating zone.")
        engine.state.add(pendingDatabaseChanges: [ .saveZone(CKRecordZone(zoneName: CloudKitConfig.zoneName)) ])
        await queueAllUsersToCloudKit()
        await queueAllSwimTimesToCloudKit()
        
        scheduleDebouncedSend()
    }
    
    func removeAllData() async {
        logDebug("☁️ Removing all data locally and on the server.")
        
        // 1. Recoge todos los IDs de todos los objetos locales
        let allUserIDs       = await fetchRecordIDs(UserEntity.fetchRequest(),       idKeyPath: \.id)
        let allSwimTimeIDs   = await fetchRecordIDs(SwimTimeEntity.fetchRequest(),   idKeyPath: \.id)
        
        
        // 2. Borra todas las entidades locales
        await removeAllUserEntities()
        await removeAllSwimTimeEntities()
        
        // 3. Marca los registros remotos para eliminación en CloudKit
        let recordRemovals: [CKSyncEngine.PendingRecordZoneChange] =
        (allUserIDs + allSwimTimeIDs).map { .deleteRecord($0) }
        engine.state.add(pendingRecordZoneChanges: recordRemovals)
        
        // 4. Borra la zona de CloudKit si quieres eliminar *todo* en la nube (opcional)
        engine.state.add(pendingDatabaseChanges: [ .deleteZone(zoneID) ])
        
        defaults.removeObject(forKey: syncTokenKey)
        
        scheduleDebouncedSend(after: 0.5)
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
            // Al empezar la sincronización
        case .willFetchChanges, .willFetchRecordZoneChanges, .willSendChanges:
            logDebug("☁️ Will process changes.")
            postOnMain(.syncStatusChanged, object: SyncStatus.syncing)
        // Al finalizar y guardar el estado
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
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        // 1) Recoge solo los cambios del scope solicitado
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !changes.isEmpty else { return nil }

        // 2) Extrae los recordNames implicados (saves y deletes)
        let idsNeeded = Set(changes.compactMap { change -> String? in
            switch change {
            case .saveRecord(let id), .deleteRecord(let id): return id.recordName
            default: return nil
            }
        })

        // Convierte una sola vez a UUID
        let uuidsNeeded: [UUID] = idsNeeded.compactMap(UUID.init(uuidString:))

        // 3) Construye snapshots *solo* con los objetos necesarios (dentro del perform del contexto)
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

        // 4) Mapa total (recordName -> CKRecord)
        let recordMap = snapshots.user
            .merging(snapshots.swimTime) { $1 }
            
        // 5) Logs (sin tocar NSManagedObject)
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

        // 6) Filtra .saveRecord que no tengan CKRecord y retíralos del estado
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

        // 7) Construye el batch: ahora el closure SIEMPRE devuelve un CKRecord válido
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
    
    // SyncEngine.swift
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
    
    func processFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) async {

        var didChangeUsers = false
        var didChangeSwimTimes = false
        
        await context.perform {
            // MODIFICACIONES
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

            // BORRADOS
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

            // Guarda dentro del mismo perform
            self.saveContextSync()
        }

        // 🔔 Notifica FUERA del perform
        if didChangeUsers      { postOnMain(.usersDidChange) }
        if didChangeSwimTimes  { postOnMain(.swimTimesDidChange) }
        
    }

    
    func processSentRecordZoneChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) async {
        
        // ✅ 1) ÉXITOS: refresca systemFields locales
        if !changes.savedRecords.isEmpty {
            await context.perform {
                for record in changes.savedRecords {
                    let name = record.recordID.recordName
                    let arch = NSKeyedArchiver(requiringSecureCoding: true)
                    record.encodeSystemFields(with: arch)
                    let data = arch.encodedData

                    // Actualiza la entidad correspondiente si existe
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
                request.predicate = NSPredicate(format: "id == %@", uuid as (any CVarArg))
                let result = (try? self.context.fetch(request))?.first
                continuation.resume(returning: result)
            }
        }
    }
    
    private func fetchUserEntitySync(by recordName: String) throws -> UserEntity? {
        guard let uuid = UUID(uuidString: recordName) else {
            throw NSError(domain: "Invalid UUID", code: 0)
        }
        let request: NSFetchRequest<UserEntity> = UserEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", uuid as (any CVarArg))
        return try context.fetch(request).first
    }


    func removeAllUserEntities() async {
        let all = await fetchAllUserEntities()
        await context.perform {
            for entity in all { self.context.delete(entity) }
            self.saveContextSync()
        }
    }

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
    
    func queueUsersToCloudKit(for users: [User]) {
        logDebug("☁️ Queuing selected Users to the sync state: \(users.count) items.")
        let recordIDs = users.map { user in
            CKRecord.ID(recordName: user.id.uuidString, zoneID: zoneID)
        }
        let changes: [CKSyncEngine.PendingRecordZoneChange] = recordIDs.map { .saveRecord($0) }
        engine.state.add(pendingRecordZoneChanges: changes)
        scheduleDebouncedSend(after: 1.0)
    }

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
                request.predicate = NSPredicate(format: "id == %@", uuid as (any CVarArg))
                let result = (try? self.context.fetch(request))?.first
                continuation.resume(returning: result)
            }
        }
    }
    
    private func fetchSwimTimeEntitySync(by recordName: String) throws -> SwimTimeEntity? {
        guard let uuid = UUID(uuidString: recordName) else {
            throw NSError(domain: "Invalid UUID", code: 0)
        }
        let request: NSFetchRequest<SwimTimeEntity> = SwimTimeEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", uuid as (any CVarArg))
        return try context.fetch(request).first
    }

    func removeAllSwimTimeEntities() async {
        let all = await fetchAllSwimTimeEntities()
        await context.perform {
            for entity in all {
                self.context.delete(entity)
            }
            self.saveContextSync()
        }
    }

    func queueAllSwimTimesToCloudKit() async {
        logDebug("☁️ Queuing all CoreData swimtimes to the sync state.")
        let ids = await fetchRecordIDs(SwimTimeEntity.fetchRequest(), idKeyPath: \.id)
        engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord($0) })
        scheduleDebouncedSend(after: 1.0)
    }
    
    func queueSwimTimesToCloudKit(for swimTimes: [SwimTime]) {
        logDebug("☁️ Queuing selected SwimTimes to the sync state: \(swimTimes.count) items.")
        let recordIDs = swimTimes.map { swimTime in
            CKRecord.ID(recordName: swimTime.id.uuidString, zoneID: zoneID)
        }
        let changes: [CKSyncEngine.PendingRecordZoneChange] = recordIDs.map { .saveRecord($0) }
        engine.state.add(pendingRecordZoneChanges: changes)
        scheduleDebouncedSend(after: 1.0)
    }

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
    //Solo llamar desde dentro de context.perform
    private func saveContextSync() {
        do {
            if context.hasChanges {
                try context.save()
            }
        } catch {
            logDebug("Error saving context: \(error)")
        }
    }
    
    private func postOnMain(_ name: Notification.Name) {
        Task { @MainActor in
            NotificationCenter.default.post(name: name, object: nil)
        }
    }

    private func postOnMain<T: Sendable>(_ name: Notification.Name, object: T?) {
        Task { @MainActor in
            NotificationCenter.default.post(name: name, object: object)
        }
    }
    
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
