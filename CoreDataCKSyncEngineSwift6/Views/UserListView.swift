//
//  ContentView.swift
//  CoreDataCKSyncEngineSwift6
//
//  Created by Javier Arnáez de Pedro on 31/7/25.
//

import SwiftUI

struct UserListView: View {
    @Binding var selectedUser: User?
    
    @EnvironmentObject var swimtimesVM: SwimTimesViewModel
    @EnvironmentObject var usersVM: UsersViewModel
    
    var body: some View {
        NavigationSplitView{
            List(selection: $selectedUser) {
                ForEach(usersVM.users) { user in
                    NavigationLink(value: user) {
                        Text(user.name)
                    }
                }
                .onDelete(perform: deleteUser)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task{
                            await usersVM.addUser(newUser: User(id: UUID(), name: randomUserName()))
                        }
                    } label: {
                        Label("New user", systemImage: "plus")
                    }
                    Button {
                        Task{
                            await modifyFirstUser()
                        }
                    } label: {
                        Label("Modify first user", systemImage: "pencil")
                    }
                }
            }
            .overlay(
                VStack {
                    Spacer()
                    // Pie de la lista: número de usuarios
                    HStack {
                        Spacer()
                        Text("Users: \(usersVM.users.count)")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .padding(.bottom, 8)
                            .padding(.trailing, 16)
                    }
                }
            )
        }detail:{
            if let _ = selectedUser{
                NavigationStack{
                    SwimTimesListView(selectedUser: $selectedUser)
                }
            }else{
                Text("No user selected")
            }
        }
    }
        
    func deleteUser(at indexSet: IndexSet) {
        guard let idx = indexSet.first, usersVM.users.indices.contains(idx) else { return }
        let idToDelete = usersVM.users[idx].id
        usersVM.deleteUser(id: idToDelete)
        selectedUser = nil
    }
    
    func modifyFirstUser() async {
        guard let first = usersVM.users.first else { return }
        await usersVM.modifyUser(id: first.id, newName: randomUserName())
    }
    
    func randomUserName() -> String {
        let names = [
            "Lucía", "Martín", "Sofía", "Lucas", "Paula", "Mateo", "Julia", "Hugo", "Emma", "Leo",
            "Valeria", "Daniel", "Carla", "Alejandro", "Martina", "Pablo", "Sara", "Adrián", "Noa", "David"
        ]
        let surnames = [
            "García", "López", "Martínez", "Sánchez", "Pérez", "González", "Rodríguez", "Fernández", "Moreno", "Jiménez",
            "Ruiz", "Hernández", "Díaz", "Álvarez", "Romero", "Navarro", "Torres", "Domínguez", "Vázquez", "Ramos"
        ]
        let name = names.randomElement() ?? "Javier"
        let surname = surnames.randomElement() ?? "Arnáez"
        return "\(name) \(surname)"
    }

}
