//
//  UserViewModel.swift
//  CoreDataCKSyncEngineSwift6
//
//  Created by Javier Arnáez de Pedro on 31/7/25.
//

import Foundation
import CoreData

@MainActor
class UsersViewModel: ObservableObject{
    @Published private(set) var users: [User] = []
    
    private let usersRepository: UsersRepository
    private let context: NSManagedObjectContext
    private let syncContext: NSManagedObjectContext
    let syncEngine: SyncEngine

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
                logDebug("Usuarios actualizados por CKSyncEngine")
                await self?.getUsers()
            }
        }
    }
    
    func getUsers() async {
        do {
            let fetchedUsers = try await usersRepository.fetchAllUsers()
            self.users = fetchedUsers
        } catch {
            logDebug("Error fetching users: \(error)")
            self.users = []
        }
    }
    
    func addUser(newUser: User) async {
        guard !newUser.name.isEmpty else {
            print("Trying to add empty user.")
            // Aquí podrías mostrar un mensaje de error en la UI
            return
        }
        guard !users.contains(newUser) else { return }
        do {
            try await usersRepository.addUser(newUser)
            self.users.append(newUser)
            await syncEngine.queueUsersToCloudKit(for: [newUser])
        } catch {
            logDebug("Error saving user: \(error)")
        }
            
    }
    
    func deleteUser(id: UUID) {
        // 1. Remove from users array right away
        users.removeAll { $0.id == id }
        // 2. Fire async cleanup (in the background)
        Task {
            await deleteAsyncUser(id: id)
        }
    }

    // Private async function for repo/sync
    private func deleteAsyncUser(id: UUID) async {
        do {
            try await usersRepository.deleteUser(withId: id)
            await syncEngine.queueUserDeletions([id])
        } catch {
            logDebug("Error deleting user: \(error)")
            // Optional: you could re-add the user if you want to support undo on failure.
        }
    }
   
    func modifyUser(id: UUID, newName: String) async {
        guard let index = users.firstIndex(where: { $0.id == id }) else { return }
        var updatedUser = users[index]
        updatedUser.name = newName
        do {
            try await usersRepository.updateUser(updatedUser)
            self.users[index] = updatedUser
            await syncEngine.queueUsersToCloudKit(for: [updatedUser])
        } catch {
            logDebug("Error updating user: \(error)")
        }
    }
    
    
}
