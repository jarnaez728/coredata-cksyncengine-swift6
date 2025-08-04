# CoreData‑CKSyncEngine‑Swift6 Demo 🚀

A Swift 6 sample project demonstrating **Core Data + CKSyncEngine** integration for CloudKit syncing. The goal is to help developers avoid the same pitfalls and serve as a working reference.

---

## ⚙️ Current Status

* **Purpose**: Established to help others by sharing a minimal Swift 6 + Core Data + CKSyncEngine reference.
* **State**: App **almost works**, pending community help and troubleshooting.
* **Known Issues**:
  * Improper context handling between main and background threads leading to sporadic memory crashes.
  * Swift 6-related compiler warnings still unresolved.
  * Updates sometimes aren’t properly synced to CloudKit.

---

## 🧩 Technologies Used

* **Core Data** — For local model storage of users and swim times.
* **CKSyncEngine** — For bridging Core Data entities to CloudKit records via a sync engine. ([GitHub][1])
* **Swift 6** — Leveraging modern language features (async/await, concurrency, new actor model).

Intended as a small yet realistic demo to illustrate integration under a Swift 6 context.

---

## 🍻 Inspiration & References

The project builds on the excellent guide by Jordan Morgan: [*"Syncing data with CloudKit in your iOS app using CKSyncEngine and Swift/SwiftUI"*](https://superwall.com/blog/syncing-data-with-cloudkit-in-your-ios-app-using-cksyncengine-and-swift-and-swiftui). Thanks for the great work!

---

## 🏊‍♀️ Project Overview

The app tracks **Users** and their associated **SwimTimes**. Features include:

* Creating and deleting users.
* Adding, modifying, and removing swim times.
* Random data generation for testing.
* Local persistence via Core Data, with syncing to CloudKit via CKSyncEngine.

Additionally, when the app is launched for the first time (or if there are no local users), it automatically checks for data in iCloud and attempts to synchronize any available records before allowing the user to interact with the app. This ensures that returning users or devices get their data downloaded and up-to-date before making any changes locally.

---

## 🗂 Repository Layout

Here’s a breakdown of the directory and file structure you can expect to see:

```
Auxiliar/
  ├── AppInitialization.swift      # Manages app startup, checks local/CloudKit user status, triggers syncs, handles loading/error states
  ├── Persistence.swift            # Sets up the CoreData stack and configures persistent store (with App Groups and migration options)
  └── SyncEngine.swift             # Wraps CKSyncEngine logic: token caching, syncing, zone/record operations, CloudKit cleanup, and CoreData <-> CloudKit bridging

Models/
  ├── SwimTime.swift               # `SwimTime` domain struct (id, date, distance, style, time, userId) and `Style` enum (stroke types)
  └── User.swift                   # `User` domain struct (id, name), equatable and hashable

Repositories/
  ├── SwimTimesRepository.swift    # CRUD operations for `SwimTime` entities in CoreData, mapping from/to domain models, batch operations, deletion by user
  └── UsersRepository.swift        # CRUD operations for `User` entities in CoreData, mapping from/to domain models

ViewModels/
  ├── SwimTimesViewModel.swift     # ObservableObject for all `SwimTime` logic: load, add, delete, modify; keeps UI in sync and queues sync changes
  └── UsersViewModel.swift         # ObservableObject for all `User` logic: load, add, delete, modify; keeps UI in sync and queues sync changes

Views/
  ├── InitialView.swift            # Main app entrypoint. Manages app state (loading, error, user selection) and triggers initialization
  ├── SwimTimesListView.swift      # List of swim times for a selected user; supports add, modify, delete operations
  └── UserListView.swift           # List of users, allows user selection, creation, deletion, and modification

CoreDataCKEngine.xcdatamodeld      # CoreData model file (defines entities and their attributes/relations)
CoreDataCKSyncEngineSwift6App.swift # App main entry point, creates view models, injects dependencies, sets up environment

```

You can adapt or rename these folders/files as needed to better reflect actual content.

---

## 🔧 Project Setup Instructions

1. Clone the repository and open the workspace in Xcode.
2. Enter your CloudKit container identifier in the project entitlements or config file.
3. Update the same identifier in `SyncEngine.swift` by changing the variable `static let identifier = "youridentifierhere"` to match your CloudKit container.
4. In Xcode target → Signing & Capabilities:
   * Enable **iCloud** with **CloudKit**.
   * Allow **Push Notification** (silent push operates CloudKit sync).
5. Build and run the app on a real device (recommended) or on a simulator signed in to an iCloud account. The app will work in the simulator, but real devices tend to provide a more reliable CloudKit sync experience.
6. Observe the logs, CloudKit console or UI to evaluate sync behavior.

---

## 🚀 Testing & Behavior

* Run the app and use the UI or "generate random" button to seed data.
* Add or edit entities and inspect whether they sync to CloudKit and across devices.
* The app logs sync actions (e.g. Save / delete record batches). Watch for warnings or failures related to threading or record updates.

---

## 🎯 Long‑Term Goal

The intention is to produce a **reliable, Swift 6-compatible reference app** showcasing CloudKit syncing via CKSyncEngine. Ultimately, this should serve as a blueprint for other apps in need of offline persistence + CloudKit integration.

---
