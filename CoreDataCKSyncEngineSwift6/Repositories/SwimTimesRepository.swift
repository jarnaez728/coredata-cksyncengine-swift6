//
//  SwimTimesRepositorory.swift
//  CoreDataCKSyncEngineSwift6
//
//  Created by Javier Arnáez de Pedro on 31/7/25.
//

import Foundation
import CoreData
import CloudKit

/// Repository layer that encapsulates CRUD operations for `SwimTime` domain objects
/// using Core Data. Provides both individual and batch operations, plus helpers
/// to convert between Core Data entities and CloudKit records.
final class SwimTimesRepository: @unchecked Sendable {
    private let context: NSManagedObjectContext
    
    init(context: NSManagedObjectContext) {
        self.context = context
    }
    
    // MARK: - CRUD operations for SwimTime
    /// Fetches all swim times from Core Data and maps them into domain models.
    func fetchAllSwimTimes() async throws -> [SwimTime] {
        try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    let request: NSFetchRequest<SwimTimeEntity> = SwimTimeEntity.fetchRequest()
                    let entities = try self.context.fetch(request)
                    let swimTimes = entities.compactMap { $0.toDomainModel() }
                    continuation.resume(returning: swimTimes)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Inserts a new SwimTime into Core Data.
    func addSwimTime(_ swimTime: SwimTime) async throws {
        try await context.perform {
            let entity = SwimTimeEntity(context: self.context)
            entity.fromDomainModel(swimTime)
            try self.context.save()
        }
    }
    
    /// Deletes a SwimTime entity with the given UUID if it exists.
    func deleteSwimTime(withId id: UUID) async throws {
        try await context.perform {
            let request: NSFetchRequest<SwimTimeEntity> = SwimTimeEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as (any CVarArg))
            if let entity = try self.context.fetch(request).first {
                self.context.delete(entity)
                try self.context.save()
            }
        }
    }
    
    /// Updates the specified fields of a SwimTime entity and returns the updated domain model.
    func updateSwimTime(id: UUID, newDate: Date, newStyle: Style, newDistance: Int, newTime: Double, newUser: UUID) async throws -> SwimTime? {
        try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    let request: NSFetchRequest<SwimTimeEntity> = SwimTimeEntity.fetchRequest()
                    request.predicate = NSPredicate(format: "id == %@", id as (any CVarArg))
                    guard let entity = try self.context.fetch(request).first else {
                        continuation.resume(returning: nil)
                        return
                    }

                    entity.date = newDate
                    entity.style = newStyle.rawValue
                    entity.distance = Int32(newDistance)
                    entity.time = newTime
                    entity.userId = newUser

                    if self.context.hasChanges {
                        try self.context.save()
                    }
                    continuation.resume(returning: entity.toDomainModel())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Performs a batch insert of multiple SwimTime domain objects using NSBatchInsertRequest.
    func batchAddSwimTimes(_ swimTimes: [SwimTime]) async throws {
        try await context.perform {
            guard !swimTimes.isEmpty else { return }
            let batchInsert = NSBatchInsertRequest(entity: SwimTimeEntity.entity(), objects: swimTimes.map { $0.dictionary })
            try self.context.execute(batchInsert)
            try self.context.save()
        }
    }
    
    /// Deletes all SwimTime entities belonging to the specified user.
    func deleteSwimTimesFromUser(userId: UUID) async throws {
        try await context.perform {
            let request: NSFetchRequest<SwimTimeEntity> = SwimTimeEntity.fetchRequest()
            request.predicate = NSPredicate(format: "userId == %@", userId as (any CVarArg))
            let results = try self.context.fetch(request)
            for entity in results {
                self.context.delete(entity)
            }
            if self.context.hasChanges {
                try self.context.save()
            }
        }
    }
    
    /// Performs a batch delete of all SwimTime entities for a given user, merging changes into the context.
    func batchDeleteSwimTimesFromUser(userId: UUID) async throws {
        try await context.perform {
            let fetchRequest: NSFetchRequest<any NSFetchRequestResult> = SwimTimeEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "userId == %@", userId as (any CVarArg))
            let batchDeleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            batchDeleteRequest.resultType = .resultTypeObjectIDs
            let result = try self.context.execute(batchDeleteRequest) as? NSBatchDeleteResult

            if let objectIDs = result?.result as? [NSManagedObjectID], !objectIDs.isEmpty {
                let changes = [NSDeletedObjectsKey: objectIDs]
                NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [self.context])
            }
        }
    }

    
}

// MARK: - Core Data <-> CloudKit / Domain mapping
/// Initializes a SwimTimeEntity from a CloudKit record. Returns nil if the recordID is invalid.
extension SwimTimeEntity {
    convenience init?(record: CKRecord, context: NSManagedObjectContext) {
        guard let uuid = UUID(uuidString: record.recordID.recordName) else {
            logDebug("❌ Invalid recordID for SwimTime: \(record.recordID.recordName)")
            return nil
        }
        self.init(context: context)
        self.id = uuid
        self.date = record["date"] as? Date
        self.distance = (record["distance"] as? NSNumber)?.int32Value ?? 0
        self.style = record["style"] as? String
        self.time = record["time"] as? Double ?? 0.0
        if let userIdStr = record["userId"] as? String {
            self.userId = UUID(uuidString: userIdStr)
        }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        self.systemFields = archiver.encodedData
    }

    /// Converts this SwimTimeEntity into a CKRecord, reusing systemFields if available to preserve metadata.
    func toCKRecord() -> CKRecord {
        precondition(self.id != nil, "id must exist before building CKRecord")
        let zoneID = CKRecordZone.ID(zoneName: CloudKitConfig.zoneName)
        let recordID = CKRecord.ID(recordName: self.id!.uuidString, zoneID: zoneID)
        if let systemFields = self.systemFields {
            do {
                let unarchiver = try NSKeyedUnarchiver(forReadingFrom: systemFields)
                unarchiver.requiresSecureCoding = true
                if let record = CKRecord(coder: unarchiver) {
                    // Update fields before returning the record
                    record["date"] = self.date
                    record["distance"] = self.distance
                    record["style"] = self.style
                    record["time"] = self.time
                    record["userId"] = self.userId?.uuidString
                    return record
                }
            } catch {
                print("❗️Error decoding systemFields: \(error)")
            }
        }
        
        let record = CKRecord(recordType: CloudKitConfig.swimTimeRecordType, recordID: recordID)
        record["date"] = self.date
        record["distance"] = Int(self.distance)
        record["style"] = self.style
        record["time"] = self.time
        record["userId"] = self.userId?.uuidString
        return record
    }
    /// Converts this SwimTimeEntity into its domain model representation.
    /// Returns nil if required fields are missing.
    func toDomainModel() -> SwimTime? {
        guard let id = self.id,
              let date = self.date,
              let styleStr = self.style,
              let style = Style(rawValue: styleStr),
              let userId = self.userId
        else {
            // If an essential field is missing, do not create a domain model
            return nil
        }
        
        return SwimTime(
            id: id,
            date: date,
            distance: Int(self.distance),
            style: style,
            time: self.time,
            userId: userId
        )
    }
    
    /// Populates the entity's fields from a SwimTime domain model.
    func fromDomainModel(_ swimTime: SwimTime) {
        self.id = swimTime.id
        self.date = swimTime.date
        self.distance = Int32(swimTime.distance)
        self.style = swimTime.style.rawValue
        self.time = swimTime.time
        self.userId = swimTime.userId
    }
}
