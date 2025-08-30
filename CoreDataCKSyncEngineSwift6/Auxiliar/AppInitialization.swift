//
//  AppInitialization.swift
//  CoreDataCKSyncEngineSwift6
//
//  Created by Javier Arnáez de Pedro on 1/8/25.
//

import Foundation
import SwiftUI

enum AppInitState: Equatable {
    case loading
    case needsUser     // No hay usuarios locales ni en CloudKit
    case ready         // Ya hay usuarios locales
    case syncingCloud  // Estamos trayendo datos de iCloud
    case waitingForSync // Hay diferencia de usuarios, esperando sincronización
    case error(String)
}

@MainActor
class AppInitialization: ObservableObject {
    
    
    @Published var state: AppInitState = .loading
    @Published var localUserCount: Int = 0
    @Published var cloudUserCount: Int = 0
    
    let usersVM: UsersViewModel
    let swimTimesVM: SwimTimesViewModel
    
    
    private var syncTimeoutTask: Task<Void, Never>?
    
    private var cloudSyncObserver: (any NSObjectProtocol)?

    init(usersVM: UsersViewModel, swimTimesVM: SwimTimesViewModel) {
        self.usersVM = usersVM
        self.swimTimesVM = swimTimesVM
    }
    
    
    func checkCloudSyncStatus() async {
        self.localUserCount = usersVM.users.count
        logDebug("Hay \(localUserCount) usuarios locales y \(cloudUserCount) usuarios en la nube")
        if localUserCount == cloudUserCount && localUserCount > 0 {
            state = .ready
            if let observer = cloudSyncObserver {
                NotificationCenter.default.removeObserver(observer)
                cloudSyncObserver = nil
            }
            syncTimeoutTask?.cancel()
        }
    }

    /// Llama a este método para inicializar la app
    func initialize() async {
        do {
            await usersVM.getUsers()
            self.localUserCount = usersVM.users.count
            await swimTimesVM.getSwimTimes()
            if usersVM.users.isEmpty {
                // Comprobamos CloudKit: ¿hay registros remotos?
                let cloudCount = try await usersVM.syncEngine.countRemoteRecordsInCloudKit(recordType: CloudKitConfig.userRecordType)
                self.cloudUserCount = cloudCount
                
                if cloudCount > 0 {
                    self.state = .syncingCloud
                    await usersVM.syncEngine.refreshDataFromCloud()
                    // Añade observer
                    cloudSyncObserver = NotificationCenter.default.addObserver(
                        forName: .cloudSyncChangesFinished,
                        object: nil,
                        queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor in
                            logDebug("AppInit: CloudKit changes received")
                            await self?.checkCloudSyncStatus()
                        }
                    }
                    
                    syncTimeoutTask?.cancel()
                    syncTimeoutTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
                        await MainActor.run {
                            guard let self else { return }
                            if self.state != .ready {
                                logDebug("AppInit: Sync timeout. Continue.")
                                self.state = .ready
                            }
                        }
                    }
                } else {
                    self.state = .needsUser
                }
            } else {
                Task{
                    await ensureAllSynced()
                }
                self.state = .ready
            }
        } catch {
            self.state = .error(error.localizedDescription)
        }
    }
    
    // Dentro de AppInitialization
    func ensureAllSynced() async {
        await usersVM.syncEngine.queueAllUsersToCloudKit()
        await swimTimesVM.syncEngine.queueAllSwimTimesToCloudKit()
        
        do {
            let localUsers = usersVM.users.count
            let localSwimTimes = swimTimesVM.swimTimes.count
            
            let cloudUsers = try await usersVM.syncEngine.countRemoteRecordsInCloudKit(recordType: CloudKitConfig.userRecordType)
            let cloudSwimTimes = try await swimTimesVM.syncEngine.countRemoteRecordsInCloudKit(recordType: CloudKitConfig.swimTimeRecordType)
            
            logDebug("[SYNC] Users: Local \(localUsers) - iCloud \(cloudUsers)")
            logDebug("[SYNC] SwimTimes: Local \(localSwimTimes) - iCloud \(cloudSwimTimes)")
        } catch {
            logDebug("[SYNC][ERROR] Error comparing local/iCloud: \(error)")
        }
    }


}
