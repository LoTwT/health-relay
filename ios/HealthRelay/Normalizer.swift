import Foundation

struct SleepSample: Codable, Equatable, Sendable {
    var uuid: String; var startMs: Int64; var endMs: Int64; var value: String
    var source: Source; var recordingMethod: String
}
struct WorkoutEvent: Codable, Equatable, Sendable { var timeMs: Int64; var type: String }
struct WorkoutSample: Codable, Equatable, Sendable {
    var uuid: String; var startMs: Int64; var endMs: Int64; var durationMs: Int64
    var activity: String; var source: Source; var recordingMethod: String
    var indoor: Bool?; var swimmingLocation: String?
    var distanceMetres: Double?; var activeKcal: Double?; var events: [WorkoutEvent]
}
struct NormalizedEntity: Codable, Equatable, Sendable { var entityId: String; var kind: String; var payload: Payload }
struct SleepNormalization: Sendable {
    var entities: [NormalizedEntity] = []; var warnings: [String] = []
    var rejected: [String:String] = [:]
    var deferred: Set<String> = []; var excludedMilliseconds: Int64 = 0; var candidateCount = 0
}
enum Normalizer {
    static let gap: Int64 = 1_800_000
    static let stageMap = ["asleep": "sleeping", "asleepUnspecified": "sleeping", "asleepCore": "light", "asleepDeep": "deep", "asleepREM": "rem", "awake": "awake"]
    static func offset(_ source: Source, _ ms: Int64) -> Int? {
        guard let name = source.timeZone, let zone = TimeZone(identifier: name) else { return nil }
        return zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(ms)/1000))
    }
    static func sleep(_ input: [SleepSample], dataset: Dataset, now: Int64, affectedUUIDs:Set<String>? = nil) throws -> SleepNormalization {
        guard let selected = dataset.sources.sleep, let history = dataset.historyStart else { return SleepNormalization() }
        let lower = try WireTime.milliseconds(history)
        var result = SleepNormalization()
        var unique: [String: SleepSample] = [:]
        for sample in input where sample.source.bundleIdentifier == selected {
            guard sample.startMs < sample.endMs else { result.warnings.append("INVALID_INTERVAL"); result.rejected[sample.uuid]="INVALID_INTERVAL"; continue }
            if let previous = unique[sample.uuid], previous != sample { throw RelayError.conflict }
            unique[sample.uuid] = sample
            if sample.value != "inBed" && stageMap[sample.value] == nil { result.warnings.append("UNSUPPORTED_SLEEP_VALUE") }
        }
        let recognized = unique.values.filter { stageMap[$0.value] != nil }.sorted {
            ($0.startMs, $0.endMs, $0.uuid) < ($1.startMs, $1.endMs, $1.uuid)
        }
        var groups: [[SleepSample]] = []; var groupEnd: Int64 = 0
        for sample in recognized {
            if groups.isEmpty || sample.startMs - groupEnd > gap { groups.append([sample]); groupEnd = sample.endMs }
            else { groups[groups.count-1].append(sample); groupEnd = max(groupEnd, sample.endMs) }
        }
        for group in groups {
            if let affectedUUIDs, Set(group.map(\.uuid)).isDisjoint(with:affectedUUIDs){continue}
            guard group.contains(where: { stageMap[$0.value] != "awake" }) else { result.warnings.append("NO_SLEEP_EVIDENCE"); continue }
            let start = group.map(\.startMs).min()!, end = group.map(\.endMs).max()!
            if end < lower { continue }
            result.candidateCount += 1
            if group.count > 10_000 || end - start > 129_600_000 { result.warnings.append("SLEEP_GROUP_TOO_LARGE"); for sample in group { result.rejected[sample.uuid]="SLEEP_GROUP_TOO_LARGE" }; continue }
            if now - end < gap { result.deferred.formUnion(group.map(\.uuid)); result.warnings.append("DEFERRED_OPEN_SLEEP"); continue }
            // Sweep half-open boundaries: duplicate evidence never adds duration.
            let boundaries = Array(Set(group.flatMap { [$0.startMs, $0.endMs] })).sorted()
            var parts: [[Stage]] = []; var current: [Stage] = []; var warnings: Set<String> = []
            var normalizedCount = 0; var excluded: Int64 = 0
            for index in 0..<(boundaries.count-1) {
                let s = boundaries[index], e = boundaries[index+1]
                let covering = group.filter { $0.startMs <= s && $0.endMs >= e }
                let types = Set(covering.compactMap { stageMap[$0.value] })
                let fine = types.subtracting(["sleeping"])
                let type: String?
                if fine.contains("awake") && fine.count > 1 { type = nil; warnings.insert("CONFLICTING_SLEEP_STAGES") }
                else if fine.count > 1 { type = "sleeping"; warnings.insert("CONFLICTING_SLEEP_STAGES") }
                else { type = fine.first ?? types.first }
                if let type {
                    if current.last?.type == type { current[current.count-1].end = WireTime.string(e) }
                    else { current.append(Stage(start: WireTime.string(s), end: WireTime.string(e), type: type)); normalizedCount += 1 }
                } else {
                    excluded += e-s; warnings.insert("SLEEP_SPLIT_FOR_UNCERTAINTY")
                    if !current.isEmpty { parts.append(current); current = [] }
                }
            }
            if !current.isEmpty { parts.append(current) }
            if normalizedCount > 10_000 { result.warnings.append("SLEEP_GROUP_TOO_LARGE"); for sample in group { result.rejected[sample.uuid]="SLEEP_GROUP_TOO_LARGE" }; continue }
            result.excludedMilliseconds += excluded
            let sampleUuids = group.map(\.uuid).sorted()
            for stages in parts where stages.contains(where: { $0.type != "awake" }) {
                let s = try WireTime.milliseconds(stages.first!.start), e = try WireTime.milliseconds(stages.last!.end)
                if e < lower { continue }
                let contributors = group.filter { sample in
                    stageMap[sample.value] != "awake" && stages.contains { stage in
                        guard stage.type != "awake", let a = try? WireTime.milliseconds(stage.start), let b = try? WireTime.milliseconds(stage.end) else { return false }
                        return sample.startMs < b && sample.endMs > a
                    }
                }.sorted { left,right in
                    func firstContribution(_ sample:SleepSample)->Int64 {
                        stages.filter{$0.type != "awake"}.compactMap { stage -> Int64? in
                            guard let a=try? WireTime.milliseconds(stage.start),let b=try? WireTime.milliseconds(stage.end),sample.startMs<b,sample.endMs>a else{return nil}
                            return max(a,sample.startMs)
                        }.min() ?? Int64.max
                    }
                    return (firstContribution(left),left.uuid)<(firstContribution(right),right.uuid)
                }
                guard let anchor = contributors.first else { continue }
                func boundaryOffset(_ t: Int64, beginning: Bool) -> Int? {
                    let candidates = group.filter { beginning ? ($0.startMs <= t && $0.endMs > t) : ($0.startMs < t && $0.endMs >= t) }
                    let offsets = candidates.map { offset($0.source,t) }
                    guard !offsets.isEmpty, offsets.allSatisfy({ $0 != nil }), Set(offsets.compactMap { $0 }).count == 1 else { return nil }
                    return offsets[0]
                }
                let p = Payload(start: WireTime.string(s), end: WireTime.string(e), startOffsetSeconds: boundaryOffset(s, beginning: true), endOffsetSeconds: boundaryOffset(e, beginning: false), source: anchor.source, recordingMethod: Set(group.map(\.recordingMethod)).count == 1 ? anchor.recordingMethod : "unknown", warnings: warnings.sorted(), anchorSampleUuid: anchor.uuid, sampleUuids: sampleUuids, stages: stages)
                result.entities.append(NormalizedEntity(entityId: "hr1/\(dataset.datasetId)/sleep/\(anchor.source.sourceKey)/\(anchor.uuid)/\(s)", kind: "sleep", payload: p))
            }
            result.warnings.append(contentsOf: warnings.sorted())
        }
        if recognized.isEmpty && !unique.isEmpty { result.warnings.append("NO_SLEEP_EVIDENCE") }
        return result
    }
    static func affectedSleepUUIDs(_ input:[SleepSample],seeds:Set<String>)->Set<String> {
        let sorted=input.filter{stageMap[$0.value] != nil}.sorted{($0.startMs,$0.endMs,$0.uuid)<($1.startMs,$1.endMs,$1.uuid)}
        var result=seeds;var group:[SleepSample]=[];var end=Int64.min
        func flush(){if !Set(group.map(\.uuid)).isDisjoint(with:seeds){result.formUnion(group.map(\.uuid))}}
        for sample in sorted {
            if !group.isEmpty && sample.startMs-end>gap{flush();group=[]}
            if group.isEmpty{end=sample.endMs}else{end=max(end,sample.endMs)}
            group.append(sample)
        };flush();return result
    }
    static let exerciseMap: [String: String] = [
        "walking":"WALKING", "running":"RUNNING", "cycling":"BIKING", "hiking":"HIKING",
        "traditionalStrengthTraining":"STRENGTH_TRAINING", "functionalStrengthTraining":"STRENGTH_TRAINING",
        "highIntensityIntervalTraining":"HIGH_INTENSITY_INTERVAL_TRAINING", "yoga":"YOGA", "pilates":"PILATES",
        "elliptical":"ELLIPTICAL", "rowing":"ROWING", "stairClimbing":"STAIR_CLIMBING", "stairs":"STAIR_CLIMBING",
        "flexibility":"STRETCHING", "dance":"DANCING", "danceInspiredTraining":"DANCING", "cardioDance":"DANCING", "socialDance":"DANCING",
        "badminton":"BADMINTON", "basketball":"BASKETBALL", "baseball":"BASEBALL", "softball":"SOFTBALL",
        "soccer":"SOCCER", "americanFootball":"FOOTBALL_AMERICAN", "australianFootball":"FOOTBALL_AUSTRALIAN", "rugby":"RUGBY",
        "tennis":"TENNIS", "tableTennis":"TABLE_TENNIS", "squash":"SQUASH", "racquetball":"RACQUETBALL",
        "volleyball":"VOLLEYBALL", "handball":"HANDBALL", "cricket":"CRICKET", "golf":"GOLF", "boxing":"BOXING",
        "martialArts":"MARTIAL_ARTS", "kickboxing":"MARTIAL_ARTS", "taiChi":"MARTIAL_ARTS", "wrestling":"MARTIAL_ARTS",
        "climbing":"ROCK_CLIMBING", "fencing":"FENCING", "gymnastics":"GYMNASTICS", "paddleSports":"PADDLING",
        "sailing":"SAILING", "surfingSports":"SURFING", "crossCountrySkiing":"SKIING", "downhillSkiing":"SKIING",
        "snowboarding":"SNOWBOARDING", "skatingSports":"SKATING", "waterPolo":"WATER_POLO", "underwaterDiving":"SCUBA_DIVING",
        "wheelchairWalkPace":"WHEELCHAIR", "wheelchairRunPace":"WHEELCHAIR"
    ]
    static func workout(_ sample: WorkoutSample, dataset: Dataset, now: Int64) throws -> NormalizedEntity? {
        guard sample.source.bundleIdentifier == dataset.sources.workout, let history = dataset.historyStart,
              sample.endMs >= (try WireTime.milliseconds(history)), sample.endMs <= now else { return nil }
        let length = sample.endMs - sample.startMs
        guard length > 0, sample.durationMs > 0, sample.durationMs <= length+1000 else { throw RelayError.invalidPayload }
        var warnings: [String] = []; var open: [String: Int64] = [:]; var raw: [(Int64,Int64)] = []; var valid = true
        for event in sample.events.sorted(by: { $0.timeMs < $1.timeMs }) {
            let channel: String
            switch event.type { case "pause", "resume": channel = "manual"; case "motionPaused", "motionResumed": channel = "motion"; default: continue }
            guard event.timeMs >= sample.startMs, event.timeMs <= sample.endMs else { valid = false; continue }
            if ["pause", "motionPaused"].contains(event.type) { if open[channel] == nil { open[channel] = event.timeMs } }
            else if let s = open.removeValue(forKey: channel) { if event.timeMs > s { raw.append((s,event.timeMs)) } }
            else { valid = false }
        }
        for s in open.values where s < sample.endMs { raw.append((s,sample.endMs)) }
        var union: [(Int64,Int64)] = []
        for item in raw.sorted(by: { $0.0 < $1.0 }) {
            if let last = union.last, item.0 <= last.1 { union[union.count-1].1 = max(last.1,item.1) } else { union.append(item) }
        }
        if abs(length-union.reduce(0) { $0+$1.1-$1.0 }-sample.durationMs) > 1000 { valid = false }
        if !valid { warnings.append("DURATION_NOT_FULLY_REPRESENTABLE"); union = [] }
        func statistic(_ value: Double?, energy: Bool) -> Statistic {
            guard let value else { warnings.append(energy ? "ACTIVE_ENERGY_UNAVAILABLE" : "DISTANCE_UNAVAILABLE"); return .unavailable }
            guard value.isFinite, value >= 0 else { warnings.append(energy ? "INVALID_ACTIVE_ENERGY" : "INVALID_DISTANCE"); return .unavailable }
            return Statistic(state: "value", metres: energy ? nil : value, kcal: energy ? value : nil)
        }
        let distance = statistic(sample.distanceMetres, energy:false), energy = statistic(sample.activeKcal, energy:true)
        let exercise: String
        if sample.activity == "swimming" { exercise = sample.swimmingLocation == "pool" ? "SWIMMING_POOL" : sample.swimmingLocation == "openWater" ? "SWIMMING_OPEN_WATER" : "OTHER_WORKOUT" }
        else { exercise = exerciseMap[sample.activity] ?? "OTHER_WORKOUT" }
        let p = Payload(start: WireTime.string(sample.startMs), end: WireTime.string(sample.endMs), startOffsetSeconds: offset(sample.source,sample.startMs), endOffsetSeconds: offset(sample.source,sample.endMs), source: sample.source, recordingMethod: sample.recordingMethod, warnings: warnings.sorted(), sourceUuid: sample.uuid, appleActivityType: sample.activity, exerciseType: exercise, durationMs: sample.durationMs, indoor: sample.indoor, pauses: union.map { Interval(start: WireTime.string($0.0),end:WireTime.string($0.1)) }, distance: distance, activeEnergy: energy)
        return NormalizedEntity(entityId: "hr1/\(dataset.datasetId)/workout/\(sample.uuid)",kind:"workout",payload:p)
    }
}
