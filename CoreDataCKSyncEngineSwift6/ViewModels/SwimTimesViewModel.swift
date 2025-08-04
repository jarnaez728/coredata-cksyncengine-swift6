//
//  SwimTimeViewModel.swift
//  CoreDataCKSyncEngineSwift6
//
//  Created by Javier Arnáez de Pedro on 31/7/25.
//

import Foundation
import CoreData

@MainActor
class SwimTimesViewModel: ObservableObject{
    @Published var swimTimes: [SwimTime] = []
    
    private let swimTimesRepository: SwimTimesRepository
    private let context: NSManagedObjectContext
    private let syncContext: NSManagedObjectContext
    let syncEngine: SyncEngine

    init(context: NSManagedObjectContext, syncContext: NSManagedObjectContext) {
        self.context = context
        self.syncContext = syncContext
        self.swimTimesRepository = SwimTimesRepository(context: context)
        self.syncEngine = SyncEngine(context: syncContext)
        
        
        // Observa cambios de sincronización para refrescar
        NotificationCenter.default.addObserver(
            forName: .swimTimesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                logDebug("Swimtimes actualizados por CKSyncEngine")
                await self?.getSwimTimes()
            }
        }
         
    }
    
    func getSwimTimes() async {
        do {
            let result = try await swimTimesRepository.fetchAllSwimTimes()
            self.swimTimes = result
        } catch {
            self.swimTimes = []
        }
    }
    
    func addSwimTime(_ newSwimTime: SwimTime) async {
        guard !swimTimes.contains(newSwimTime) else {
            logDebug("Tiempo repetido: \(newSwimTime)")
            return
        }
        do {
            try await swimTimesRepository.addSwimTime(newSwimTime)
            await MainActor.run {
                swimTimes.append(newSwimTime)
            }
            await syncEngine.queueSwimTimesToCloudKit(for: [newSwimTime])
        } catch {
            logDebug("Tiempo duplicado o error: \(error.localizedDescription)")
        }
    }
    
    func deleteSwimTime(id: UUID) {
        // 1. Remove from arrays immediately (UI expects this!)
        guard let deletedSwimTime = swimTimes.first(where: { $0.id == id }) else { return }
        swimTimes.removeAll { $0.id == id }
        
        // 2. Now perform async deletion in the background
        Task {
            await deleteAsyncSwimTime(id: id)
        }
            
    }
    
    private func deleteAsyncSwimTime(id: UUID) async {
        do {
            try await swimTimesRepository.deleteSwimTime(withId: id)
            await syncEngine.queueSwimTimeDeletions([id])
        } catch {
            logDebug("Error borrando tiempo: \(error.localizedDescription)")
            // Optionally, restore item if you want "undo" support
        }
    }

   
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
                if let idx = self.swimTimes.firstIndex(where: { $0.id == id }), let originalSwimTime = swimTimes.first(where: {$0.id == id}) {
                    self.swimTimes[idx] = updated
                }
                await syncEngine.queueSwimTimesToCloudKit(for: [updated])
            }
        } catch {
            logDebug("Error updating swimtime: \(error)")
        }
    }
    
}
