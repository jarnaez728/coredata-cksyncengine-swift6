//
//  InitialView.swift
//  CoreDataCKSyncEngineSwift6
//
//  Created by Javier Arnáez de Pedro on 1/8/25.
//

import SwiftUI

struct InitialView: View {
    @EnvironmentObject var usersVM: UsersViewModel
    @EnvironmentObject var swimtimesVM: SwimTimesViewModel
    @State var selectedUser: User? = nil
    
    @StateObject private var appInitializer: AppInitialization
     
    
    init(usersVM: UsersViewModel, swimTimesVM: SwimTimesViewModel) {
        _appInitializer = StateObject(wrappedValue: AppInitialization(usersVM: usersVM, swimTimesVM: swimTimesVM))
    }
    
    var body: some View {
        Group {
            switch appInitializer.state {
            case .loading, .syncingCloud, .waitingForSync:
                // Loading overlay, you can customize its appearance
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()
                    ProgressView( appInitializer.state == .loading ? "Loading data..." : "Syncing from iCloud...")
                        .progressViewStyle(CircularProgressViewStyle())
                        .padding(30)
                        .background(.ultraThinMaterial)
                        .cornerRadius(16)
                }
            case .needsUser, .ready:
                UserListView(selectedUser: $selectedUser)
            case .error(let msg):
                VStack {
                    Text("Startup error: \(msg)")
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await appInitializer.initialize() }
                    }
                    .padding(.top, 20)
                }
                .padding()
            }
        }
        .task {
            // Launch only once when entering the screen
            if appInitializer.state == .loading {
                await appInitializer.initialize()
            }
        }
    }
}
