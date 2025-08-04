//
//  SwimTime.swift
//  CoreDataCKSyncEngineSwift6
//
//  Created by Javier Arnáez de Pedro on 31/7/25.
//

import Foundation

struct SwimTime: Identifiable, Hashable, Equatable, CustomDebugStringConvertible{
    var id: UUID
    var date: Date
    var distance: Int
    var style: Style
    var time: Double
    var userId: UUID
    
    
    
    var debugDescription: String{
        let dateString = SwimTime.dateFormatterYMD.string(from: date)
        //return "Fecha: \(dateString) - Estilo: \(style.rawValue) - Distancia: \(distance) - Tiempo: \(time)"
        return "Fecha: \(dateString) - Estilo: \(style.rawValue) - Distancia: \(distance) - Tiempo: \(time) - UserId: \(userId.uuidString)"
    }
    
    var dictionary: [String: Any] {
        return ["id": id, "date": date, "style": style.rawValue, "distance": Int16(distance), "time": time, "userId": userId]
    }
    
    static func ==(lhs: SwimTime, rhs: SwimTime) -> Bool {
        return lhs.date == rhs.date && lhs.distance == rhs.distance && lhs.style == rhs.style && lhs.time == rhs.time && lhs.userId == rhs.userId
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(date)
        hasher.combine(style)
        hasher.combine(time)
        hasher.combine(distance)
        hasher.combine(userId)
    }
    
    static let dateFormatterYMD: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()
}


enum Style: String, Codable, Hashable, CaseIterable{
    case freestyle
    case breaststroke
    case butterfly
    case backstroke
    case medley
    case freestyle_relay
    case medley_relay
}
