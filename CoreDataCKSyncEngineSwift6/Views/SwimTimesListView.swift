//
//  UserDetailView.swift
//  CoreDataCKSyncEngineSwift6
//
//  Created by Javier Arnáez de Pedro on 31/7/25.
//

import SwiftUI

struct SwimTimesListView: View {
    @EnvironmentObject var swimtimesVM: SwimTimesViewModel
    
    @Binding var selectedUser: User?
    
    var userSwimTimes: [SwimTime] {
        if let user = selectedUser{
            return swimtimesVM.swimTimes.filter { $0.userId == user.id }
        }
        return []
    }
    
    var body: some View {
        if let user = selectedUser{
            VStack {
                if userSwimTimes.isEmpty {
                    Spacer()
                    Text("No swim times. Create one!")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    List {
                        ForEach(userSwimTimes) { swimTime in
                            VStack(alignment: .leading) {
                                SwimTimeRowView(swimtime: swimTime)
                            }
                        }
                        .onDelete(perform: deleteSwimTime)
                    }
                    .overlay(
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Text("SwimTimes: \(userSwimTimes.count)")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                    .padding(.bottom, 8)
                                    .padding(.trailing, 16)
                            }
                        }
                    )
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task{
                            await swimtimesVM.addSwimTime(newSwimTime(for: user))
                        }
                    } label: {
                        Label("New SwimTime", systemImage: "plus")
                    }
                    Button {
                        Task{
                            await modifyFirstTime()
                        }
                    } label: {
                        Label("Modify first swimTime", systemImage: "pencil")
                    }
                }
            }
            .navigationTitle(user.name)
        }
    }
    
    func deleteSwimTime(at offsets: IndexSet) {
        guard let idx = offsets.first, userSwimTimes.indices.contains(idx) else { return }
        let idToDelete = userSwimTimes[idx].id
        swimtimesVM.deleteSwimTime(id: idToDelete)
    }
    
    func modifyFirstTime() async {
        guard let user = selectedUser, let first = userSwimTimes.first else { return }
        
        // Random new values
        let newDistance = [50, 100, 200, 400, 800, 1500].randomElement()!
        let newStyle = Style.allCases.randomElement()!
        let newTime = Double.random(in: 25.0...120.0)
        let newDate = Date() // Or keep the previous value
        
        await swimtimesVM.modifySwimTime(
            id: first.id,
            newDate: newDate,
            newStyle: newStyle,
            newDistance: newDistance,
            newTime: newTime,
            newUser: user.id
        )
    }

}

// Para generar un SwimTime aleatorio:
func newSwimTime(for user: User) -> SwimTime {
    return SwimTime(
        id: UUID(),
        date: Date(),
        distance: [50, 100, 200, 400, 800, 1500].randomElement()!,
        style: Style.allCases.randomElement()!,
        time: Double.random(in: 25.0...120.0),
        userId: user.id
    )
}

struct SwimTimeRowView: View{
    var swimtime: SwimTime
    
    var body: some View{
        VStack{
            HStack{
                Text(swimtime.style.rawValue)
                Spacer()
                Text("\(swimtime.distance)m")
            }
            HStack{
                Text(SwimTime.dateFormatter.string(from: swimtime.date))
                Spacer()
                Text(swimtime.time.time_short)
            }
            .font(.footnote)
        }
        .frame(minHeight: 40)
    }
}

extension Double {
    var hours: Int {
        return Int(self / 3600)
    }
    var minutes: Int {
        return (Int(self) % 3600) / 60
    }
    var seconds: Int {
        return Int(self) % 60
    }
    var hundredths: Int {
        return Int(((self - Double(Int(self))) * 100).rounded())
    }
    var milliseconds: Int {
        return Int(((self - Double(Int(self))) * 1000).rounded())
    }
    
    var time: String{
        var fulltime: String = ""
        if (self.hours > 0){
            fulltime = String(self.hours) + "h "
        }
        fulltime += String(format: "%02d", self.minutes) + "m " + String(format: "%02d", self.seconds) + "s " + String(format: "%02d", self.hundredths) + "cs"
        return fulltime
    }
    
    var time_short: String{
        var fulltime: String = ""
        if (self.hours > 0){
            fulltime = String(self.hours) + ":"
        }
        fulltime += String(format: "%02d", self.minutes) + ":" + String(format: "%02d", self.seconds) + "." + String(format: "%02d", self.hundredths)
        return fulltime
    }
    
    var time_short_sec: String{
        var fulltime: String = ""
        if (self.hours > 0){
            fulltime = String(self.hours) + ":"
        }
        fulltime += String(format: "%02d", self.minutes) + ":" + String(format: "%02d", self.seconds)
        return fulltime
    }
}
