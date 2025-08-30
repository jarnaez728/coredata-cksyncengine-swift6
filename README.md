# CoreData-CKSyncEngine-Swift6 Demo 🚀 ![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![License: MIT](https://img.shields.io/badge/License-MIT-blue)

A Swift 6 sample project demonstrating **Core Data + CKSyncEngine** integration for CloudKit syncing.  
The goal is to provide a clear reference implementation for others, highlighting pitfalls and best practices.

---

## 📑 Table of Contents
- [Current Status](#-current-status)
- [Technologies Used](#-technologies-used)
- [Architecture](#-architecture)
- [Inspiration & References](#-inspiration--references)
- [Project Overview](#-project-overview)
- [Repository Layout](#-repository-layout)
- [Setup Instructions](#-setup-instructions)
- [Testing & Behavior](#-testing--behavior)
- [Long-Term Goal](#-long-term-goal)
- [Contributing](#-contributing)
- [License](#-license)

---

## ⚙️ Current Status

* **Purpose**: Provide a clean, functional reference for Core Data + CloudKit syncing via `CKSyncEngine`.
* **State**: The project **compiles and runs successfully with Swift 6**, with no compiler warnings. It is fully functional as a demo and can serve as a starting point for production apps.
* **Areas for Improvement**:
  * **Concurrency** — Remove remaining `@unchecked Sendable` workarounds and validate correct separation of main vs. background contexts to eliminate potential race conditions or random crashes.
  * **Thread Safety** — Review context usage to ensure operations are always performed on the correct queue/actor.
  * **Swifty Improvements** — Refine APIs and code style to align with modern Swift best practices.
  * **Sync Robustness** — Further testing to guarantee that all record updates consistently propagate to CloudKit in edge cases.

Contributions, bug reports, and suggestions are welcome!

---

## 🧩 Technologies Used

* **Core Data** — Local persistence for `User` and `SwimTime` entities.  
* **CKSyncEngine** — Bridges Core Data objects to CloudKit records. ([Apple Docs][1])  
* **Swift 6** — Using modern concurrency (async/await, structured concurrency, `@MainActor`).  
* **SwiftUI** — UI layer bound to `ObservableObject` view models.

---

## 🏗 Architecture

The app is structured in clean layers to separate responsibilities:
```
SwiftUI Views ─▶ ViewModels (ObservableObject, @MainActor)
                │
                ▼
        Repositories (CRUD in Core Data)
                │
                ▼
          SyncEngine (bridges Core Data ↔ CloudKit)
```
Key points:
- **ViewModels**: Run on the main actor, expose `@Published` state for the UI.
- **Repositories**: Encapsulate Core Data CRUD operations.
- **SyncEngine**: Manages CloudKit zones, sync tokens, conflict resolution, and debounced sends.
- **System Fields**: Stored in Core Data entities to preserve CloudKit metadata (e.g. etags).

---
## 🍻 Inspiration & References

This project builds on the excellent guide by Jordan Morgan:  
[*"Syncing data with CloudKit in your iOS app using CKSyncEngine and Swift/SwiftUI"*](https://superwall.com/blog/syncing-data-with-cloudkit-in-your-ios-app-using-cksyncengine-and-swift-and-swiftui).  
Many thanks for the great work and inspiration!

In addition, I’ve learned from countless forum discussions, sought help from a freelance developer,  
and of course relied on AI assistance — especially **ChatGPT-5** — to refine, debug, and document this demo project.

---

## 🏊 Project Overview

The app tracks **Users** and their associated **SwimTimes**.  

Features include:
- Creating and deleting users.
- Adding, modifying, and removing swim times.
- Local persistence in Core Data.
- Automatic CloudKit sync via `CKSyncEngine`.

On first launch (or when no local users exist), the app fetches any iCloud data before allowing interaction, ensuring consistency across devices.

---

## 🗂 Repository Layout
```
Auxiliar/
├── AppInitialization.swift      # Handles startup, checks local vs. iCloud, triggers syncs
├── Persistence.swift            # Core Data stack setup, migration, app group support
└── SyncEngine.swift             # Wraps CKSyncEngine: token caching, zone ops, conflict resolution

Models/
├── SwimTime.swift               # Domain model + enums (Style, DistanceUnit, etc.)
└── User.swift                   # Domain model for User (id, name, gender, birthdate)

Repositories/
├── SwimTimesRepository.swift    # CRUD for SwimTimeEntity, domain <-> Core Data <-> CloudKit mapping
└── UsersRepository.swift        # CRUD for UserEntity, domain <-> Core Data <-> CloudKit mapping

ViewModels/
├── SwimTimesViewModel.swift     # ObservableObject managing swim times (add/update/delete)
└── UsersViewModel.swift         # ObservableObject managing users (add/update/delete)

Views/
├── InitialView.swift            # Entry point, handles init states (loading, error, syncing)
├── SwimTimesListView.swift      # UI for listing and editing swim times
└── UserListView.swift           # UI for managing users

CoreDataCKEngine.xcdatamodeld      # Core Data model schema
CoreDataCKSyncEngineSwift6App.swift # Main entry point, sets up dependencies and environment
```
---

## 🔧 Setup Instructions

1. Clone the repository and open the workspace in Xcode.
2. Enter your **CloudKit container identifier** in the entitlements file.
3. Update the same identifier in `CloudKitConfig.identifier` inside `SyncEngine.swift`.
4. In **Signing & Capabilities** for the target:
   * Enable **iCloud** with **CloudKit**.
   * Enable **Push Notifications** (silent pushes trigger CloudKit sync).
5. Run on a real device (preferred) or simulator signed into iCloud.
6. Observe the logs or CloudKit dashboard for sync events.

---

## 🚀 Testing & Behavior

* Run the app and create users or swim times.  
* Check iCloud Dashboard or run on a second device to confirm syncing.  
* Logs print detailed sync events (saves, deletes, conflicts, etc.).  

---

## 🎯 Long-Term Goal

The aim is to build a **reliable Swift 6 reference app** for CloudKit syncing with Core Data.  
It should serve as a **blueprint** for any app needing offline persistence and seamless iCloud sync.

---

## 🤝 Contributing

Contributions are very welcome!  
The project is functional, but there are several areas where the community can help improve stability and polish:

### Priority Areas
- **Concurrency & Thread Safety**  
  - Remove `@unchecked Sendable` workarounds by ensuring proper actor isolation.  
  - Double-check that main and background `NSManagedObjectContext`s are clearly separated and safe from race conditions.

- **Swifty API Improvements**  
  - Refactor code to better leverage modern Swift 6 patterns (e.g. `actors`, structured concurrency, clearer async APIs).  
  - Improve naming consistency and remove boilerplate where possible.

- **Sync Robustness**  
  - Stress-test the sync engine to guarantee consistent propagation of updates to CloudKit.  
  - Expand conflict resolution strategies for edge cases.

- **Testing**  
  - Add unit tests for repositories, view models, and sync flows.  
  - Introduce integration tests with CloudKit (where feasible).

### How to contribute
1. Fork the repo
2. Create a feature branch (`git checkout -b feature/my-improvement`)
3. Commit your changes
4. Open a Pull Request 🚀

Bug reports, feature requests, and discussions are also very valuable!  

---

## 📄 License

MIT License.  
Feel free to use, adapt, and share.

---

[1]: https://developer.apple.com/documentation/cloudkit/cksynceengine
