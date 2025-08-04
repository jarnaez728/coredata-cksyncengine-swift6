//
//  Persistence.swift
//  CoreDataCKSyncEngineSwift6
//
//  Created by Javier Arnáez de Pedro on 31/7/25.
//

import CoreData

struct PersistenceController {
    static let shared = PersistenceController()
    
    let container: NSPersistentContainer
    var persistentContainer: NSPersistentContainer { container }
    
    var mainContext: NSManagedObjectContext {
        container.viewContext
    }

    init(inMemory: Bool = false) {
        let databaseName = "CoreDataCKEngine.sqlite"
        let appGroupName = "group.jarnaez.CoreDataCKEngine"
        let containerName = "CoreDataCKEngine"

        let sharedStoreURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupName)!
            .appendingPathComponent(databaseName)

        container = NSPersistentContainer(name: containerName)
        
        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        } else {
            container.persistentStoreDescriptions.first?.url = sharedStoreURL
        }
        
        container.persistentStoreDescriptions.first?.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        container.persistentStoreDescriptions.first?.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        container.persistentStoreDescriptions.first?.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)

        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }else {
                print("✅ Core Data loaded store at \(storeDescription.url?.absoluteString ?? "nil")")
            }
        })
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
}

