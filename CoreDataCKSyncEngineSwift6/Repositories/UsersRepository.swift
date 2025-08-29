//
//  UsersRepository.swift
//  CoreDataCKSyncEngineSwift6
//
//  Created by Javier Arnáez de Pedro on 31/7/25.
//

import Foundation
import CoreData
import CloudKit

final class UsersRepository: @unchecked Sendable {
    private let context: NSManagedObjectContext
    
    init(context: NSManagedObjectContext) {
        self.context = context
    }

    // MARK: - Fetch all users
    func fetchAllUsers() async throws -> [User] {
        try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    let request: NSFetchRequest<UserEntity> = UserEntity.fetchRequest()
                    let entities = try self.context.fetch(request)
                    continuation.resume(returning: entities.compactMap { $0.toDomainModel() })
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Add user
    func addUser(_ user: User) async throws {
        try await context.perform {
            guard !user.name.isEmpty else {
                return
            }
            let entity = UserEntity(context: self.context)
            entity.fromDomainModel(user)
            try self.context.save()
        }
    }

    // MARK: - Delete user
    func deleteUser(withId id: UUID) async throws {
        try await context.perform {
            let request: NSFetchRequest<UserEntity> = UserEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as (any CVarArg))
            if let entity = try self.context.fetch(request).first {
                self.context.delete(entity)
                try self.context.save()
            }
        }
    }

    // MARK: - Update user
    func updateUser(_ user: User) async throws {
        try await context.perform {
            let request: NSFetchRequest<UserEntity> = UserEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", user.id as (any CVarArg))
            if let entity = try self.context.fetch(request).first {
                entity.fromDomainModel(user)
                try self.context.save()
            }
        }
    }
}

// MARK: - Mapping extension
extension UserEntity {
    convenience init?(record: CKRecord, context: NSManagedObjectContext) {
        guard let uuid = UUID(uuidString: record.recordID.recordName) else {
            logDebug("❌ Invalid recordID for User: \(record.recordID.recordName)")
            return nil
        }
        self.init(context: context)
        self.id = uuid
        self.name = record["name"] as? String
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        self.systemFields = archiver.encodedData
    }
    
    // Pasar a CKRecord
    func toCKRecord() -> CKRecord {
        precondition(self.id != nil, "id must exist before building CKRecord")
        let zoneID = CKRecordZone.ID(zoneName: CloudKitConfig.zoneName)
        let recordID = CKRecord.ID(recordName: self.id!.uuidString, zoneID: zoneID)
        
        if let systemFields = self.systemFields {
            do {
                let unarchiver = try NSKeyedUnarchiver(forReadingFrom: systemFields)
                unarchiver.requiresSecureCoding = true
                if let record = CKRecord(coder: unarchiver) {
                    // Actualiza los campos modificados
                    record["name"] = self.name
                    return record
                }
            } catch {
                logDebug("❗️Error decoding systemFields: \(error)")
            }
        }
        
        let record = CKRecord(recordType: CloudKitConfig.userRecordType, recordID: recordID)
        
        record["name"] = self.name
        return record
    }
    func toDomainModel() -> User? {
        guard let id = self.id,
              let name = self.name else {
            return nil
        }
        return User(id: id, name: name)
    }

    func fromDomainModel(_ user: User) {
        self.id = user.id
        self.name = user.name
    }
}
