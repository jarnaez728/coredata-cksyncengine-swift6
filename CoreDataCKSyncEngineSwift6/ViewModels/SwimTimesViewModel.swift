//
//  SwimTimeViewModel.swift
//  CoreDataCKSyncEngineSwift6
//
//  Created by Javier Arnáez de Pedro on 31/7/25.
//

import Foundation
import CoreData

/// ViewModel for managing SwimTime domain objects.
/// Bridges the UI with the `SwimTimesRepository` and `SyncEngine`.
/// Ensures published swim times stay in sync with Core Data and CloudKit.
@MainActor
class SwimTimesViewModel: ObservableObject{
    @Published var swimTimes: [SwimTime] = []
    
    private let swimTimesRepository: SwimTimesRepository
    private let context: NSManagedObjectContext
    private let syncContext: NSManagedObjectContext
    let syncEngine: SyncEngine

    /// Creates a new SwimTimesViewModel with separate contexts for UI and sync.
    /// Sets up an observer to refresh swim times when the sync engine reports changes.
    init(context: NSManagedObjectContext, syncContext: NSManagedObjectContext) {
        self.context = context
        self.syncContext = syncContext
        self.swimTimesRepository = SwimTimesRepository(context: context)
        self.syncEngine = SyncEngine(context: syncContext)
        
        
        // Observe sync notifications to refresh swim times when CloudKit updates arrive
        NotificationCenter.default.addObserver(
            forName: .swimTimesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                logDebug("SwimTimes updated by CKSyncEngine")
                await self?.getSwimTimes()
            }
        }
         
    }
    
    /// Loads all swim times from the repository and updates the published array.
    /// Clears the array if fetching fails.
    func getSwimTimes() async {
        do {
            let result = try await swimTimesRepository.fetchAllSwimTimes()
            self.swimTimes = result
        } catch {
            self.swimTimes = []
        }
    }
    
    /// Adds a new swim time if it does not already exist, persists it, updates the UI,
    /// and queues it for CloudKit synchronization.
    func addSwimTime(_ newSwimTime: SwimTime) async {
        guard !swimTimes.contains(newSwimTime) else {
            logDebug("Duplicate swim time: \(newSwimTime)")
            return
        }
        do {
            try await swimTimesRepository.addSwimTime(newSwimTime)
            await MainActor.run {
                swimTimes.append(newSwimTime)
            }
            syncEngine.queueSwimTimesToCloudKit(for: [newSwimTime])
        } catch {
            logDebug("Duplicate time or error: \(error.localizedDescription)")
        }
    }
    
    /// Deletes a swim time by ID. Removes it from the UI immediately and then performs
    /// the repository & CloudKit deletion asynchronously.
    func deleteSwimTime(id: UUID) {
        // 1. Remove from arrays immediately (UI expects this!)
        guard swimTimes.first(where: { $0.id == id }) != nil else { return }
        swimTimes.removeAll { $0.id == id }
        
        // 2. Now perform async deletion in the background
        Task {
            await deleteAsyncSwimTime(id: id)
        }
            
    }
    
    private func deleteAsyncSwimTime(id: UUID) async {
        do {
            try await swimTimesRepository.deleteSwimTime(withId: id)
            syncEngine.queueSwimTimeDeletions([id])
        } catch {
            logDebug("Error deleting swim time: \(error.localizedDescription)")
            // Optionally, restore item if you want "undo" support
        }
    }
    
    /// Deletes all swim times associated with the given user.
    /// Removes the swim times from memory immediately for instant UI update,
    /// then performs asynchronous deletion from the repository and queues their deletion in CloudKit.
    func deleteSwimTimesFromUser(userId: UUID) {
        // 1. Remove in-memory
        let userSwimTimeIds = Set(swimTimes.filter { $0.userId == userId }.map { $0.id })
        swimTimes.removeAll { $0.userId == userId }
        
        // 2. Start async background cleanup
        Task {
            await deleteAsyncSwimTimesFromUser(userId: userId, swimTimeIds: userSwimTimeIds)
        }
    }
    
    /// Performs the actual Core Data deletion for all swim times of a user,
    /// and queues their deletion in CloudKit.
    private func deleteAsyncSwimTimesFromUser(userId: UUID, swimTimeIds: Set<UUID>) async {
        do {
            try await swimTimesRepository.batchDeleteSwimTimesFromUser(userId: userId)
            syncEngine.queueSwimTimeDeletions(Array(swimTimeIds))
        } catch {
            logDebug("Error deleting swimtimes from \(userId): \(error)")
            // Optionally: Revert in-memory deletion or show an error
        }
    }

   
    /// Modifies an existing swim time by updating its fields, saving to Core Data, and
    /// queuing the updated record for CloudKit synchronization.
    func modifySwimTime(id: UUID, newDate: Date, newStyle: Style, newDistance: Int, newTime: Double, newUser: UUID) async {
        guard let index = swimTimes.firstIndex(where: { $0.id == id }) else { return }
        var updatedSwimTime = swimTimes[index]
        updatedSwimTime.date = newDate
        updatedSwimTime.style = newStyle
        updatedSwimTime.distance = newDistance
        updatedSwimTime.time = newTime
        
        self.swimTimes[index] = updatedSwimTime
        do {
            if let updated = try await swimTimesRepository.updateSwimTime(id: id, newDate: newDate, newStyle: newStyle, newDistance: newDistance, newTime: newTime, newUser: newUser) {
                if let idx = self.swimTimes.firstIndex(where: { $0.id == id }) {
                    self.swimTimes[idx] = updated
                }
                syncEngine.queueSwimTimesToCloudKit(for: [updated])
            }
        } catch {
            logDebug("Error updating swimtime: \(error)")
        }
    }
    
}
