//
//  SwimTimesRepositorory.swift
//  CoreDataCKSyncEngineSwift6
//
//  Created by Javier Arnáez de Pedro on 31/7/25.
//

import Foundation
import CoreData
import CloudKit

final class SwimTimesRepository {
    private let context: NSManagedObjectContext
    
    init(context: NSManagedObjectContext) {
        self.context = context
    }
    
    // MARK: - Métodos CRUD para SwimTime
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
    
    func addSwimTime(_ swimTime: SwimTime) async throws {
        try await context.perform {
            let entity = SwimTimeEntity(context: self.context)
            entity.fromDomainModel(swimTime)
            try self.context.save()
        }
    }
    
    func deleteSwimTime(withId id: UUID) async throws {
        try await context.perform {
            let request: NSFetchRequest<SwimTimeEntity> = SwimTimeEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            if let entity = try self.context.fetch(request).first {
                self.context.delete(entity)
                try self.context.save()
            }
        }
    }
    
    func updateSwimTime(id: UUID, newDate: Date, newStyle: Style, newDistance: Int, newTime: Double, newUser: UUID) async throws -> SwimTime? {
        try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    let request: NSFetchRequest<SwimTimeEntity> = SwimTimeEntity.fetchRequest()
                    request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
                    guard let entity = try self.context.fetch(request).first else {
                        continuation.resume(returning: nil)
                        return
                    }

                    entity.date = newDate
                    entity.style = newStyle.rawValue
                    entity.distance = Int16(newDistance)
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

    func batchAddSwimTimes(_ swimTimes: [SwimTime]) async throws {
        try await context.perform {
            guard !swimTimes.isEmpty else { return }
            let batchInsert = NSBatchInsertRequest(entity: SwimTimeEntity.entity(), objects: swimTimes.map { $0.dictionary })
            try self.context.execute(batchInsert)
            try self.context.save()
        }
    }
    
    func deleteSwimTimesFromUser(userId: UUID) async throws {
        try await context.perform {
            let request: NSFetchRequest<SwimTimeEntity> = SwimTimeEntity.fetchRequest()
            request.predicate = NSPredicate(format: "userId == %@", userId as CVarArg)
            let results = try self.context.fetch(request)
            for entity in results {
                self.context.delete(entity)
            }
            if self.context.hasChanges {
                try self.context.save()
            }
        }
    }
    
    func batchDeleteSwimTimesFromUser(userId: UUID) async throws {
        try await context.perform {
            let fetchRequest: NSFetchRequest<NSFetchRequestResult> = SwimTimeEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "userId == %@", userId as CVarArg)
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

// MARK: - Convertir de CoreData a SwimTime
extension SwimTimeEntity {
    convenience init(record: CKRecord, context: NSManagedObjectContext) {
        self.init(context: context)
        self.id = UUID(uuidString: record.recordID.recordName) ?? UUID()
        self.date = record["date"] as? Date
        self.distance = Int16(record["distance"] as? Int ?? 0)
        self.style = record["style"] as? String
        self.time = record["time"] as? Double ?? 0.0
        if let userIdStr = record["userId"] as? String {
            self.userId = UUID(uuidString: userIdStr)
        }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        self.systemFields = archiver.encodedData
    }

    // Pasar a CKRecord
    func toCKRecord() -> CKRecord {
        let zoneID = CKRecordZone.ID(zoneName: CloudKitConfig.zoneName)
        let recordID = CKRecord.ID(recordName: self.id?.uuidString ?? UUID().uuidString, zoneID: zoneID)
        if let systemFields = self.systemFields {
            do {
                let unarchiver = try NSKeyedUnarchiver(forReadingFrom: systemFields)
                unarchiver.requiresSecureCoding = true
                if let record = CKRecord(coder: unarchiver) {
                    // Actualiza campos
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
    func toDomainModel() -> SwimTime? {
        guard let id = self.id,
              let date = self.date,
              let styleStr = self.style,
              let style = Style(rawValue: styleStr),
              let userId = self.userId
        else {
            // Si algún campo esencial falla, no se crea el modelo
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
    
    func fromDomainModel(_ swimTime: SwimTime) {
        self.id = swimTime.id
        self.date = swimTime.date
        self.distance = Int16(swimTime.distance)
        self.style = swimTime.style.rawValue
        self.time = swimTime.time
        self.userId = swimTime.userId
    }
}
