//
//  UserViewModel.swift
//  CoreDataCKSyncEngineSwift6
//
//  Created by Javier Arnáez de Pedro on 31/7/25.
//

import Foundation
import CoreData

/// ViewModel that manages `User` domain models for the UI layer.
/// Bridges Core Data (via `UsersRepository`) and CloudKit (via `SyncEngine`).
/// Listens to sync notifications and refreshes the in-memory list accordingly.
@MainActor
class UsersViewModel: ObservableObject{
    @Published private(set) var users: [User] = []
    
    private let usersRepository: UsersRepository
    private let context: NSManagedObjectContext
    private let syncContext: NSManagedObjectContext
    let syncEngine: SyncEngine

    /// Creates a new UsersViewModel.
    /// - Parameters:
    ///   - context: Core Data context used by the repository (UI-facing).
    ///   - syncContext: Dedicated Core Data context used by the sync engine.
    /// Sets up a listener that refreshes the users list whenever CloudKit pushes changes.
    init(context: NSManagedObjectContext, syncContext: NSManagedObjectContext) {
        self.context = context
        self.syncContext = syncContext
        self.usersRepository = UsersRepository(context: context)
        self.syncEngine = SyncEngine(context: syncContext)
                
        
        NotificationCenter.default.addObserver(
            forName: .usersDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                logDebug("Users updated by CKSyncEngine")
                await self?.getUsers()
            }
        }
    }
    
    /// Loads all users from the repository and updates the published array.
    /// On failure, logs the error and clears the array.
    func getUsers() async {
        do {
            let fetchedUsers = try await usersRepository.fetchAllUsers()
            self.users = fetchedUsers.sorted { $0.name < $1.name }
        } catch {
            logDebug("Error fetching users: \(error)")
            self.users = []
        }
    }
    
    /// Adds a new user if it does not already exist, persists it to Core Data,
    /// updates the published array, and queues it for CloudKit sync.
    func addUser(newUser: User) async {
        guard !newUser.name.isEmpty else {
            print("Trying to add empty user.")
            // You could surface a validation error in the UI here
            return
        }
        guard !users.contains(newUser) else { return }
        do {
            try await usersRepository.addUser(newUser)
            self.users.append(newUser)
            syncEngine.queueUsersToCloudKit(for: [newUser])
        } catch {
            logDebug("Error saving user: \(error)")
        }
            
    }
    
    /// Deletes a user by ID. Removes it from the in-memory list immediately and
    /// then performs the repository and CloudKit deletion asynchronously.
    func deleteUser(id: UUID) {
        // 1. Remove from users array right away
        users.removeAll { $0.id == id }
        // 2) Perform async cleanup (repository + CloudKit)
        Task {
            await deleteAsyncUser(id: id)
        }
    }

    /// Performs the actual deletion in Core Data and enqueues the CloudKit deletion.
    private func deleteAsyncUser(id: UUID) async {
        do {
            try await usersRepository.deleteUser(withId: id)
            syncEngine.queueUserDeletions([id])
        } catch {
            logDebug("Error deleting user and swimtimes: \(error)")
            // Optional: you could re-add the user if you want to support undo on failure.
        }
    }
   
    /// Updates a user's name, persists the change, updates the published array,
    /// and enqueues the updated record for CloudKit synchronization.
    func modifyUser(id: UUID, newName: String) async {
        guard let index = users.firstIndex(where: { $0.id == id }) else { return }
        var updatedUser = users[index]
        updatedUser.name = newName
        do {
            try await usersRepository.updateUser(updatedUser)
            self.users[index] = updatedUser
            syncEngine.queueUsersToCloudKit(for: [updatedUser])
        } catch {
            logDebug("Error updating user: \(error)")
        }
    }
    
    
}
