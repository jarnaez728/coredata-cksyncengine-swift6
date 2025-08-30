//
//  UsersRepository.swift
//  CoreDataCKSyncEngineSwift6
//
//  Created by Javier Arnáez de Pedro on 31/7/25.
//

import Foundation
import CoreData
import CloudKit

/// Repository layer that encapsulates CRUD operations for `User` domain models
/// backed by Core Data. It exposes async methods that marshal work onto the
/// managed object context and maps to/from CloudKit when needed.
final class UsersRepository: @unchecked Sendable {
    private let context: NSManagedObjectContext
    
    init(context: NSManagedObjectContext) {
        self.context = context
    }

    // MARK: - Fetch all users
    /// Returns all users stored in Core Data as domain models.
    /// - Throws: Any error produced by the underlying Core Data fetch.
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
    /// Inserts a new `User` into Core Data.
    /// - Parameter user: The domain model to persist.
    /// - Note: No-op if the provided name is empty.
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
    /// Deletes the user with the given identifier if it exists.
    /// - Parameter id: The domain identifier (UUID).
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
    /// Updates an existing user by matching on its identifier.
    /// - Parameter user: The full domain model containing new values.
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

// MARK: - Core Data <-> CloudKit mapping
extension UserEntity {
    /// Initializes a `UserEntity` from a CloudKit record.
    /// Returns `nil` when the record identifier is not a valid UUID.
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
    
    // Convert to CKRecord
    /// Converts this Core Data entity into a `CKRecord`, reusing `systemFields`
    /// when available to preserve CloudKit metadata (change tags, creation info, etc.).
    func toCKRecord() -> CKRecord {
        precondition(self.id != nil, "id must exist before building CKRecord")
        let zoneID = CKRecordZone.ID(zoneName: CloudKitConfig.zoneName)
        let recordID = CKRecord.ID(recordName: self.id!.uuidString, zoneID: zoneID)
        
        if let systemFields = self.systemFields {
            do {
                let unarchiver = try NSKeyedUnarchiver(forReadingFrom: systemFields)
                unarchiver.requiresSecureCoding = true
                if let record = CKRecord(coder: unarchiver) {
                    // Update modified fields
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
    /// Maps the Core Data entity into the `User` domain model.
    /// Returns `nil` if required fields are missing.
    func toDomainModel() -> User? {
        guard let id = self.id,
              let name = self.name else {
            return nil
        }
        return User(id: id, name: name)
    }

    /// Populates the Core Data entity from a `User` domain model.
    func fromDomainModel(_ user: User) {
        self.id = user.id
        self.name = user.name
    }
}
