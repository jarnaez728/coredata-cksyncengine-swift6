//
//  CoreDataCKSyncEngineSwift6App.swift
//  CoreDataCKSyncEngineSwift6
//
//  Created by Javier Arnáez de Pedro on 31/7/25.
//

import SwiftUI

@main
struct CoreDataCKSyncEngineSwift6App: App {
    @StateObject var swimTimesVM: SwimTimesViewModel
    @StateObject var usersVM: UsersViewModel
    
    init() {
        let persistence = PersistenceController.shared
        let mainContext = persistence.mainContext
        let backgroundContext = persistence.container.newBackgroundContext()
        backgroundContext.automaticallyMergesChangesFromParent = true
        
        _swimTimesVM = StateObject(wrappedValue: SwimTimesViewModel(context: mainContext, syncContext: backgroundContext))
        _usersVM = StateObject(wrappedValue: UsersViewModel(context: mainContext, syncContext: backgroundContext))
    }
    
    var body: some Scene {
        WindowGroup {
            InitialView(usersVM: usersVM, swimTimesVM: swimTimesVM)
                .environmentObject(swimTimesVM)
                .environmentObject(usersVM)
                .task{
                    usersVM.syncEngine.ensureZoneExists()
                    await usersVM.syncEngine.printRemoteCloudKitRecords()
                }
        }
    }
}
