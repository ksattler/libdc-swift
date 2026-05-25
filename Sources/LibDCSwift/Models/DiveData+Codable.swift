import Foundation
import Clibdivecomputer

// MARK: - PPO2Reading (Codable wrapper for ppo2Readings tuples)

public struct PPO2Reading: Codable {
    public let sensor: UInt32
    public let value: Double
}

// MARK: - DiveEvent + Codable

extension DiveEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, mandatory
    }

    private enum EventType: String, Codable {
        case ascent, violation, decoStop, gasChange, bookmark, safetyStop, ceiling, po2, deepStop
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ascent:       try container.encode(EventType.ascent, forKey: .type)
        case .violation:    try container.encode(EventType.violation, forKey: .type)
        case .decoStop:     try container.encode(EventType.decoStop, forKey: .type)
        case .gasChange:    try container.encode(EventType.gasChange, forKey: .type)
        case .bookmark:     try container.encode(EventType.bookmark, forKey: .type)
        case .safetyStop(let mandatory):
            try container.encode(EventType.safetyStop, forKey: .type)
            try container.encode(mandatory, forKey: .mandatory)
        case .ceiling:      try container.encode(EventType.ceiling, forKey: .type)
        case .po2:          try container.encode(EventType.po2, forKey: .type)
        case .deepStop:     try container.encode(EventType.deepStop, forKey: .type)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(EventType.self, forKey: .type)
        switch type {
        case .ascent:       self = .ascent
        case .violation:    self = .violation
        case .decoStop:     self = .decoStop
        case .gasChange:    self = .gasChange
        case .bookmark:     self = .bookmark
        case .safetyStop:
            let mandatory = try container.decode(Bool.self, forKey: .mandatory)
            self = .safetyStop(mandatory: mandatory)
        case .ceiling:      self = .ceiling
        case .po2:          self = .po2
        case .deepStop:     self = .deepStop
        }
    }
}

// MARK: - DiveProfilePoint + Codable

extension DiveProfilePoint: Codable {
    private enum CodingKeys: String, CodingKey {
        case time, depth, temperature, pressure, po2, pn2, phe, events
        case ndl, decoStop, decoTime, tts, currentGas, cns
        case rbt, heartbeat, bearing, setpoint, diveMode
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(time, forKey: .time)
        try container.encode(depth, forKey: .depth)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encodeIfPresent(pressure, forKey: .pressure)
        try container.encodeIfPresent(po2, forKey: .po2)
        try container.encodeIfPresent(pn2, forKey: .pn2)
        try container.encodeIfPresent(phe, forKey: .phe)
        try container.encode(events, forKey: .events)
        try container.encodeIfPresent(ndl, forKey: .ndl)
        try container.encodeIfPresent(decoStop, forKey: .decoStop)
        try container.encodeIfPresent(decoTime, forKey: .decoTime)
        try container.encodeIfPresent(tts, forKey: .tts)
        try container.encodeIfPresent(currentGas, forKey: .currentGas)
        try container.encodeIfPresent(cns, forKey: .cns)
        try container.encodeIfPresent(rbt, forKey: .rbt)
        try container.encodeIfPresent(heartbeat, forKey: .heartbeat)
        try container.encodeIfPresent(bearing, forKey: .bearing)
        try container.encodeIfPresent(setpoint, forKey: .setpoint)
        try container.encodeIfPresent(diveMode, forKey: .diveMode)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            time: try container.decode(TimeInterval.self, forKey: .time),
            depth: try container.decode(Double.self, forKey: .depth),
            temperature: try container.decodeIfPresent(Double.self, forKey: .temperature),
            pressure: try container.decodeIfPresent(Double.self, forKey: .pressure),
            po2: try container.decodeIfPresent(Double.self, forKey: .po2),
            pn2: try container.decodeIfPresent(Double.self, forKey: .pn2),
            phe: try container.decodeIfPresent(Double.self, forKey: .phe),
            events: try container.decode([DiveEvent].self, forKey: .events),
            ndl: try container.decodeIfPresent(UInt32.self, forKey: .ndl),
            decoStop: try container.decodeIfPresent(Double.self, forKey: .decoStop),
            decoTime: try container.decodeIfPresent(UInt32.self, forKey: .decoTime),
            tts: try container.decodeIfPresent(UInt32.self, forKey: .tts),
            currentGas: try container.decodeIfPresent(Int.self, forKey: .currentGas),
            cns: try container.decodeIfPresent(Double.self, forKey: .cns),
            rbt: try container.decodeIfPresent(UInt32.self, forKey: .rbt),
            heartbeat: try container.decodeIfPresent(UInt32.self, forKey: .heartbeat),
            bearing: try container.decodeIfPresent(UInt32.self, forKey: .bearing),
            setpoint: try container.decodeIfPresent(Double.self, forKey: .setpoint),
            diveMode: try container.decodeIfPresent(DiveData.DiveMode.self, forKey: .diveMode)
        )
    }
}

// MARK: - GasMix + Codable

extension GasMix: Codable {
    private enum CodingKeys: String, CodingKey {
        case helium, oxygen, nitrogen, usage
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(helium, forKey: .helium)
        try container.encode(oxygen, forKey: .oxygen)
        try container.encode(nitrogen, forKey: .nitrogen)
        try container.encode(usage.rawValue, forKey: .usage)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            helium: try container.decode(Double.self, forKey: .helium),
            oxygen: try container.decode(Double.self, forKey: .oxygen),
            nitrogen: try container.decode(Double.self, forKey: .nitrogen),
            usage: dc_usage_t(rawValue: try container.decode(UInt32.self, forKey: .usage))
        )
    }
}

// MARK: - DiveData.DiveMode + Codable

extension DiveData.DiveMode: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "freedive":            self = .freedive
        case "gauge":               self = .gauge
        case "openCircuit":         self = .openCircuit
        case "closedCircuit":       self = .closedCircuit
        case "semiClosedCircuit":   self = .semiClosedCircuit
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown DiveMode: \(value)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .freedive:             try container.encode("freedive")
        case .gauge:                try container.encode("gauge")
        case .openCircuit:          try container.encode("openCircuit")
        case .closedCircuit:        try container.encode("closedCircuit")
        case .semiClosedCircuit:    try container.encode("semiClosedCircuit")
        }
    }
}

// MARK: - DiveData.Tank.Usage + Codable

extension DiveData.Tank.Usage: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "none":        self = .none
        case "oxygen":      self = .oxygen
        case "diluent":     self = .diluent
        case "sidemount":   self = .sidemount
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown Tank.Usage: \(value)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none:         try container.encode("none")
        case .oxygen:       try container.encode("oxygen")
        case .diluent:      try container.encode("diluent")
        case .sidemount:    try container.encode("sidemount")
        }
    }
}

// MARK: - DiveData.Tank + Codable

extension DiveData.Tank: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, volume, workingPressure, beginPressure, endPressure, gasMix, usage
        case beginTime, endTime
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(volume, forKey: .volume)
        try container.encode(workingPressure, forKey: .workingPressure)
        try container.encode(beginPressure, forKey: .beginPressure)
        try container.encode(endPressure, forKey: .endPressure)
        try container.encode(gasMix, forKey: .gasMix)
        try container.encode(usage, forKey: .usage)
        try container.encodeIfPresent(beginTime, forKey: .beginTime)
        try container.encodeIfPresent(endTime, forKey: .endTime)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decodeIfPresent(String.self, forKey: .name),
            volume: try container.decode(Double.self, forKey: .volume),
            workingPressure: try container.decode(Double.self, forKey: .workingPressure),
            beginPressure: try container.decode(Double.self, forKey: .beginPressure),
            endPressure: try container.decode(Double.self, forKey: .endPressure),
            gasMix: try container.decode(Int.self, forKey: .gasMix),
            usage: try container.decode(Usage.self, forKey: .usage),
            beginTime: try container.decodeIfPresent(TimeInterval.self, forKey: .beginTime),
            endTime: try container.decodeIfPresent(TimeInterval.self, forKey: .endTime)
        )
    }
}

// MARK: - DiveData.DecoStop + Codable

extension DiveData.DecoStop: Codable {
    private enum CodingKeys: String, CodingKey {
        case depth, time, type
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(depth, forKey: .depth)
        try container.encode(time, forKey: .time)
        try container.encode(type, forKey: .type)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            depth: try container.decode(Double.self, forKey: .depth),
            time: try container.decode(TimeInterval.self, forKey: .time),
            type: try container.decode(Int.self, forKey: .type)
        )
    }
}

// MARK: - DiveData.Location + Codable

extension DiveData.Location: Codable {
    private enum CodingKeys: String, CodingKey {
        case latitude, longitude, altitude
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encodeIfPresent(altitude, forKey: .altitude)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            latitude: try container.decode(Double.self, forKey: .latitude),
            longitude: try container.decode(Double.self, forKey: .longitude),
            altitude: try container.decodeIfPresent(Double.self, forKey: .altitude)
        )
    }
}

// MARK: - DiveData.DecoModel.DecoType + Codable

extension DiveData.DecoModel.DecoType: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "none":        self = .none
        case "buhlmann":    self = .buhlmann
        case "vpm":         self = .vpm
        case "rgbm":        self = .rgbm
        case "dciem":       self = .dciem
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown DecoType: \(value)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none:         try container.encode("none")
        case .buhlmann:     try container.encode("buhlmann")
        case .vpm:          try container.encode("vpm")
        case .rgbm:         try container.encode("rgbm")
        case .dciem:        try container.encode("dciem")
        }
    }
}

// MARK: - DiveData.DecoModel + Codable

extension DiveData.DecoModel: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, conservatism, gfLow, gfHigh
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(conservatism, forKey: .conservatism)
        try container.encodeIfPresent(gfLow, forKey: .gfLow)
        try container.encodeIfPresent(gfHigh, forKey: .gfHigh)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            type: try container.decode(DecoType.self, forKey: .type),
            conservatism: try container.decode(Int.self, forKey: .conservatism),
            gfLow: try container.decodeIfPresent(UInt32.self, forKey: .gfLow),
            gfHigh: try container.decodeIfPresent(UInt32.self, forKey: .gfHigh)
        )
    }
}

// MARK: - DiveData + Codable

extension DiveData: Codable {
    private enum CodingKeys: String, CodingKey {
        case number, datetime, maxDepth, avgDepth, divetime, temperature
        case profile, tankPressure, gasMix, gasMixCount, gasMixes
        case salinity, atmospheric, surfaceTemperature, minTemperature, maxTemperature
        case tankCount, tanks, diveMode, decoModel, location
        case rbt, heartbeat, bearing, setpoint, ppo2Readings, cns, decoStop
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(number, forKey: .number)
        try container.encode(datetime, forKey: .datetime)
        try container.encode(maxDepth, forKey: .maxDepth)
        try container.encode(avgDepth, forKey: .avgDepth)
        try container.encode(divetime, forKey: .divetime)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(profile, forKey: .profile)
        try container.encode(tankPressure, forKey: .tankPressure)
        try container.encodeIfPresent(gasMix, forKey: .gasMix)
        try container.encodeIfPresent(gasMixCount, forKey: .gasMixCount)
        try container.encodeIfPresent(gasMixes, forKey: .gasMixes)
        try container.encodeIfPresent(salinity, forKey: .salinity)
        try container.encodeIfPresent(atmospheric, forKey: .atmospheric)
        try container.encodeIfPresent(surfaceTemperature, forKey: .surfaceTemperature)
        try container.encodeIfPresent(minTemperature, forKey: .minTemperature)
        try container.encodeIfPresent(maxTemperature, forKey: .maxTemperature)
        try container.encodeIfPresent(tankCount, forKey: .tankCount)
        try container.encodeIfPresent(tanks, forKey: .tanks)
        try container.encodeIfPresent(diveMode, forKey: .diveMode)
        try container.encodeIfPresent(decoModel, forKey: .decoModel)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encodeIfPresent(rbt, forKey: .rbt)
        try container.encodeIfPresent(heartbeat, forKey: .heartbeat)
        try container.encodeIfPresent(bearing, forKey: .bearing)
        try container.encodeIfPresent(setpoint, forKey: .setpoint)
        try container.encodeIfPresent(cns, forKey: .cns)
        try container.encodeIfPresent(decoStop, forKey: .decoStop)

        let readings = ppo2Readings.map { PPO2Reading(sensor: $0.sensor, value: $0.value) }
        try container.encode(readings, forKey: .ppo2Readings)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let readings = try container.decode([PPO2Reading].self, forKey: .ppo2Readings)

        self.init(
            number: try container.decode(Int.self, forKey: .number),
            datetime: try container.decode(Date.self, forKey: .datetime),
            maxDepth: try container.decode(Double.self, forKey: .maxDepth),
            avgDepth: try container.decode(Double.self, forKey: .avgDepth),
            divetime: try container.decode(TimeInterval.self, forKey: .divetime),
            temperature: try container.decode(Double.self, forKey: .temperature),
            profile: try container.decode([DiveProfilePoint].self, forKey: .profile),
            tankPressure: try container.decode([Double].self, forKey: .tankPressure),
            gasMix: try container.decodeIfPresent(Int.self, forKey: .gasMix),
            gasMixCount: try container.decodeIfPresent(Int.self, forKey: .gasMixCount),
            gasMixes: try container.decodeIfPresent([GasMix].self, forKey: .gasMixes),
            salinity: try container.decodeIfPresent(Double.self, forKey: .salinity),
            atmospheric: try container.decodeIfPresent(Double.self, forKey: .atmospheric),
            surfaceTemperature: try container.decodeIfPresent(Double.self, forKey: .surfaceTemperature),
            minTemperature: try container.decodeIfPresent(Double.self, forKey: .minTemperature),
            maxTemperature: try container.decodeIfPresent(Double.self, forKey: .maxTemperature),
            tankCount: try container.decodeIfPresent(Int.self, forKey: .tankCount),
            tanks: try container.decodeIfPresent([Tank].self, forKey: .tanks),
            diveMode: try container.decodeIfPresent(DiveMode.self, forKey: .diveMode),
            decoModel: try container.decodeIfPresent(DecoModel.self, forKey: .decoModel),
            location: try container.decodeIfPresent(Location.self, forKey: .location),
            rbt: try container.decodeIfPresent(UInt32.self, forKey: .rbt),
            heartbeat: try container.decodeIfPresent(UInt32.self, forKey: .heartbeat),
            bearing: try container.decodeIfPresent(UInt32.self, forKey: .bearing),
            setpoint: try container.decodeIfPresent(Double.self, forKey: .setpoint),
            ppo2Readings: readings.map { (sensor: $0.sensor, value: $0.value) },
            cns: try container.decodeIfPresent(Double.self, forKey: .cns),
            decoStop: try container.decodeIfPresent(DecoStop.self, forKey: .decoStop)
        )
    }
}
