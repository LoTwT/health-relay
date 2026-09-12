import Foundation
import CryptoKit

enum RelayError: String, Error, Codable {
    case invalidPayload = "INVALID_PAYLOAD", incompatible = "PROTOCOL_INCOMPATIBLE"
    case tooLarge = "RECORD_TOO_LARGE", unavailable = "SOURCE_RECORD_UNAVAILABLE"
    case recovery = "RECOVERY_REQUIRED", conflict = "VERSION_CONFLICT"
    case history = "HISTORY_RANGE_MISMATCH", source = "SOURCE_CONFIG_MISMATCH"
    case authentication = "AUTHENTICATION_FAILED", certificate = "CERTIFICATE_MISMATCH"
    case network = "CONNECTION_INTERRUPTED", storage = "STORAGE_UNAVAILABLE"
}
func sha256(_ value: String) -> String { sha256(Data(value.utf8)) }
func sha256(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
func newID() -> String { UUID().uuidString.lowercased() }

enum WireTime {
    static func string(_ ms: Int64) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
    static func milliseconds(_ value: String) throws -> Int64 {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression) != nil else { throw RelayError.invalidPayload }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: value) else { throw RelayError.invalidPayload }
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        guard string(ms) == value else { throw RelayError.invalidPayload }; return ms
    }
    static func now() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
}
struct Sources: Codable, Equatable, Sendable { var sleep: String?; var workout: String? }
struct Dataset: Codable, Equatable, Sendable {
    var datasetId: String
    var historyStart: String?
    var sources: Sources
}
struct Source: Codable, Equatable, Sendable {
    var bundleIdentifier: String
    var sourceKey: String
    var name: String?
    var deviceType: String?
    var manufacturer: String?
    var model: String?
    var timeZone: String?
}
struct Interval: Codable, Equatable, Sendable { var start: String; var end: String }
struct Stage: Codable, Equatable, Sendable { var start: String; var end: String; var type: String }
struct Statistic: Codable, Equatable, Sendable {
    var state: String
    var metres: Double?
    var kcal: Double?
    static let unavailable = Statistic(state: "unavailable")
}
struct Payload: Codable, Equatable, Sendable {
    var start: String
    var end: String
    var startOffsetSeconds: Int?
    var endOffsetSeconds: Int?
    var source: Source
    var recordingMethod: String
    var warnings: [String]
    var anchorSampleUuid: String?
    var sampleUuids: [String]?
    var stages: [Stage]?
    var sourceUuid: String?
    var appleActivityType: String?
    var exerciseType: String?
    var durationMs: Int64?
    var indoor: Bool?
    var pauses: [Interval]?
    var distance: Statistic?
    var activeEnergy: Statistic?
    var dependencies: Set<String> { Set(sampleUuids ?? sourceUuid.map { [$0] } ?? []) }
}
struct Change: Codable, Equatable, Sendable {
    var entityId: String
    var version: Int64
    var kind: String
    var action: String
    var payload: Payload?
}
struct ChangeSet: Codable, Equatable, Sendable { var changeSetId: String; var changes: [Change] }
struct RebuildPlan: Codable, Equatable, Sendable {
    var planId: String; var oldDatasetId: String?; var newDatasetId: String
    var historyStart: String; var sources: Sources
}
struct PairingCode: Codable, Sendable {
    var `protocol`: Int; var receiverId: String; var ip: String; var port: UInt16
    var certificateFingerprint: String; var pairingId: String; var pairingSecret: String
}
struct Pairing: Codable, Sendable {
    var receiverId: String; var certificateFingerprint: String; var pairId: String
    var pairToken: String; var senderId: String; var mode: String; var ip: String; var port: UInt16
}

// Optional source metadata and offsets are explicit JSON null on the wire.
// Kind-specific absent fields stay absent. Int64 travels through JSONEncoder, never Double.
enum WireCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        func normalize(_ object: Any) -> Any {
            if let list = object as? [Any] { return list.map(normalize) }
            guard var map = object as? [String: Any] else { return object }
            for (key, value) in map { map[key] = normalize(value) }
            var nullable: [String] = []
            if map["bundleIdentifier"] != nil { nullable = ["name", "deviceType", "manufacturer", "model", "timeZone"] }
            if map["recordingMethod"] != nil { nullable += ["startOffsetSeconds", "endOffsetSeconds"]; if map["sourceUuid"] != nil { nullable += ["indoor"] } }
            if map["sleep"] != nil || map["workout"] != nil || map.isEmpty { nullable += ["sleep", "workout"] }
            for key in nullable where map[key] == nil { map[key] = NSNull() }
            return map
        }
        return try JSONSerialization.data(withJSONObject: normalize(object), options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }
    static func frame(_ data: Data) throws -> Data {
        guard (1...1_048_576).contains(data.count) else { throw RelayError.tooLarge }
        var n = UInt32(data.count).bigEndian
        return withUnsafeBytes(of: &n) { Data($0) } + data
    }
    static func frameLength(_ bytes: Data) throws -> Int {
        guard bytes.count == 4 else { throw RelayError.invalidPayload }
        let count = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard (1...1_048_576).contains(count) else { throw RelayError.tooLarge }; return Int(count)
    }
}

struct Contract {
    static let exerciseTypes: Set<String> = ["WALKING","RUNNING","BIKING","HIKING","SWIMMING_POOL","SWIMMING_OPEN_WATER","STRENGTH_TRAINING","HIGH_INTENSITY_INTERVAL_TRAINING","YOGA","PILATES","ELLIPTICAL","ROWING","STAIR_CLIMBING","STRETCHING","DANCING","BADMINTON","BASKETBALL","BASEBALL","SOFTBALL","SOCCER","FOOTBALL_AMERICAN","FOOTBALL_AUSTRALIAN","RUGBY","TENNIS","TABLE_TENNIS","SQUASH","RACQUETBALL","VOLLEYBALL","HANDBALL","CRICKET","GOLF","BOXING","MARTIAL_ARTS","ROCK_CLIMBING","FENCING","GYMNASTICS","PADDLING","SAILING","SURFING","SKIING","SNOWBOARDING","SKATING","WATER_POLO","SCUBA_DIVING","WHEELCHAIR","OTHER_WORKOUT"]
    static let warningCodes: Set<String> = ["UNSUPPORTED_SLEEP_VALUE","CONFLICTING_SLEEP_STAGES","SLEEP_SPLIT_FOR_UNCERTAINTY","DEFERRED_OPEN_SLEEP","NO_SLEEP_EVIDENCE","SLEEP_GROUP_TOO_LARGE","DURATION_NOT_FULLY_REPRESENTABLE","DISTANCE_UNAVAILABLE","ACTIVE_ENERGY_UNAVAILABLE","INVALID_DISTANCE","INVALID_ACTIVE_ENERGY","OVERLAPPING_WORKOUTS","INVALID_INTERVAL"]
    static let sleepTypes: Set<String> = ["sleeping", "light", "deep", "rem", "awake"]
    static func validUUID(_ value:String)->Bool {value.range(of:"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",options:.regularExpression) != nil}
    static func validate(_ group: ChangeSet, dataset: Dataset) throws {
        guard validUUID(group.changeSetId), validUUID(dataset.datasetId), !group.changes.isEmpty,
              Set(group.changes.map(\.entityId)).count == group.changes.count,
              Set(group.changes.map(\.version)).count == 1 else { throw RelayError.invalidPayload }
        for change in group.changes {
            guard change.version > 0, ["sleep", "workout"].contains(change.kind), ["upsert", "delete"].contains(change.action),
                  change.entityId.hasPrefix("hr1/\(dataset.datasetId)/\(change.kind)/") else { throw RelayError.invalidPayload }
            let suffix=String(change.entityId.dropFirst("hr1/\(dataset.datasetId)/\(change.kind)/".count))
            if change.kind=="workout"{guard validUUID(suffix) else{throw RelayError.invalidPayload}}
            else {
                let parts=suffix.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
                guard parts.count==3,parts[0].range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil,
                      validUUID(parts[1]),let epoch=Int64(parts[2]),String(epoch)==parts[2] else{throw RelayError.invalidPayload}
            }
            if change.action == "delete" { guard change.payload == nil else { throw RelayError.invalidPayload }; continue }
            guard let p = change.payload else { throw RelayError.invalidPayload }
            let start = try WireTime.milliseconds(p.start), end = try WireTime.milliseconds(p.end)
            guard let history=dataset.historyStart,end >= (try WireTime.milliseconds(history)),
                  !p.source.bundleIdentifier.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,p.source.bundleIdentifier.count<=255,
                  [p.source.name,p.source.deviceType,p.source.manufacturer,p.source.model,p.source.timeZone].allSatisfy({$0 == nil || (!$0!.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0!.count<=120)}),
                  p.warnings.count<=100,p.warnings.allSatisfy({warningCodes.contains($0)}),
                  start < end, p.source.sourceKey == sha256(p.source.bundleIdentifier),
                  p.source.bundleIdentifier == (change.kind == "sleep" ? dataset.sources.sleep : dataset.sources.workout),
                  ["automatic", "active", "manual", "unknown"].contains(p.recordingMethod),
                  [p.startOffsetSeconds, p.endOffsetSeconds].allSatisfy({ $0 == nil || (-64800...64800).contains($0!) }) else { throw RelayError.invalidPayload }
            if change.kind == "sleep" {
                guard p.sourceUuid == nil,p.durationMs == nil,p.distance == nil,p.activeEnergy == nil,let anchor = p.anchorSampleUuid, validUUID(anchor),
                      let samples = p.sampleUuids, samples.count<=10000,samples.allSatisfy(validUUID),samples == Array(Set(samples)).sorted(), samples.contains(anchor),
                      let stages = p.stages, !stages.isEmpty, stages.count <= 10_000, end-start <= 129_600_000,
                      change.entityId == "hr1/\(dataset.datasetId)/sleep/\(p.source.sourceKey)/\(anchor)/\(start)" else { throw RelayError.invalidPayload }
                var cursor = start; var asleep = false
                for stage in stages {
                    let s = try WireTime.milliseconds(stage.start), e = try WireTime.milliseconds(stage.end)
                    guard s == cursor, e > s, e <= end, Self.sleepTypes.contains(stage.type) else { throw RelayError.invalidPayload }
                    cursor = e; asleep = asleep || stage.type != "awake"
                }
                guard cursor == end, asleep else { throw RelayError.invalidPayload }
            } else {
                guard p.stages == nil,p.sampleUuids == nil,p.anchorSampleUuid == nil,let uuid = p.sourceUuid, validUUID(uuid),
                      change.entityId == "hr1/\(dataset.datasetId)/workout/\(uuid)", let duration = p.durationMs,
                      duration > 0, duration <= end-start+1000, let pauses = p.pauses,
                      pauses.count<=10000,let activity=p.appleActivityType,!activity.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,activity.count<=120,let exercise=p.exerciseType,exerciseTypes.contains(exercise) else { throw RelayError.invalidPayload }
                var cursor = start;var paused:Int64=0
                for pause in pauses {
                    let s = try WireTime.milliseconds(pause.start), e = try WireTime.milliseconds(pause.end)
                    guard s >= cursor, e > s, e <= end else { throw RelayError.invalidPayload }; cursor = e;paused += e-s
                }
                guard pauses.isEmpty || abs(end-start-paused-duration)<=1000 else{throw RelayError.invalidPayload}
                for (stat, unit) in [(p.distance, "metres"), (p.activeEnergy, "kcal")] {
                    guard let stat else { throw RelayError.invalidPayload }
                    let value = unit == "metres" ? stat.metres : stat.kcal
                    guard (stat.state == "unavailable" && stat.metres == nil && stat.kcal == nil) ||
                            (stat.state == "value" && value != nil && value!.isFinite && value! >= 0 && (unit=="metres" ? stat.kcal==nil:stat.metres==nil)) else { throw RelayError.invalidPayload }
                }
            }
        }
    }
}
