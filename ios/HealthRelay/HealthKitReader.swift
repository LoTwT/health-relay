import Foundation
@preconcurrency import HealthKit

struct SourceChoice: Sendable {
    var bundleIdentifier: String; var name: String; var devices: Set<String>
    var latestMs: Int64; var count: Int; var recognizableWatch: Bool
}
struct HealthPage: Sendable {
    var sleep: [SleepSample]; var workouts: [WorkoutSample]; var deletions: [String]; var anchor: Data
    var empty: Bool { sleep.isEmpty && workouts.isEmpty && deletions.isEmpty }
}
final class HealthKitReader: @unchecked Sendable {
    let store = HKHealthStore()
    static let sleepType = HKCategoryType(.sleepAnalysis)
    static let workoutType = HKObjectType.workoutType()
    static let quantityIds: [HKQuantityTypeIdentifier] = [.activeEnergyBurned,.distanceWalkingRunning,.distanceCycling,.distanceSwimming,.distanceWheelchair]
    func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw RelayError.unavailable }
        let read: Set<HKObjectType> = Set([Self.sleepType,Self.workoutType] + Self.quantityIds.map { HKQuantityType($0) })
        try await store.requestAuthorization(toShare: [], read: read)
    }
    func page(kind: String, lowerMs: Int64, anchorData: Data?) async throws -> HealthPage {
        let anchor: HKQueryAnchor?
        if let anchorData {
            do { anchor = try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: anchorData) }
            catch { throw RelayError.recovery }
            guard anchor != nil else { throw RelayError.recovery }
        } else { anchor = nil }
        let predicate = HKQuery.predicateForSamples(withStart: Date(timeIntervalSince1970: Double(lowerMs)/1000), end: nil, options: [])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: kind == "sleep" ? Self.sleepType : Self.workoutType, predicate: predicate, anchor: anchor, limit: 500) { _, samples, deleted, next, error in
                if let error { continuation.resume(throwing:error); return }
                guard let next else { continuation.resume(throwing:RelayError.unavailable); return }
                do {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: next, requiringSecureCoding: true)
                    continuation.resume(returning: HealthPage(sleep:(samples ?? []).compactMap { ($0 as? HKCategorySample).map(Self.sleep) },workouts:(samples ?? []).compactMap { ($0 as? HKWorkout).map(Self.workout) },deletions:(deleted ?? []).map { $0.uuid.uuidString.lowercased() },anchor:data))
                } catch { continuation.resume(throwing:error) }
            }
            store.execute(query)
        }
    }
    func readUUIDs(kind: String, uuids: [String]) async throws -> HealthPage {
        guard uuids.count <= 100 else { throw RelayError.tooLarge }
        let ids = Set(uuids.compactMap(UUID.init(uuidString:)))
        let predicate = HKQuery.predicateForObjects(with: ids)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: kind == "sleep" ? Self.sleepType : Self.workoutType,predicate:predicate,limit:100,sortDescriptors:nil) { _, samples, error in
                if let error { continuation.resume(throwing:error); return }
                continuation.resume(returning: HealthPage(sleep:(samples ?? []).compactMap { ($0 as? HKCategorySample).map(Self.sleep) },workouts:(samples ?? []).compactMap { ($0 as? HKWorkout).map(Self.workout) },deletions:[],anchor:Data()))
            }; store.execute(query)
        }
    }
    func sources(kind: String, lowerMs: Int64) async throws -> [SourceChoice] {
        var cursor: Data?; var choices: [String:SourceChoice] = [:]
        while true {
            let page = try await page(kind:kind,lowerMs:lowerMs,anchorData:cursor)
            for (source,end) in page.sleep.map({ ($0.source,$0.endMs) }) + page.workouts.map({ ($0.source,$0.endMs) }) {
                var c = choices[source.bundleIdentifier] ?? SourceChoice(bundleIdentifier:source.bundleIdentifier,name:source.name ?? source.bundleIdentifier,devices:[],latestMs:end,count:0,recognizableWatch:false)
                if let model = source.model { c.devices.insert(model) }
                c.recognizableWatch = c.recognizableWatch || source.deviceType == "watch"
                c.latestMs = max(c.latestMs,end); c.count += 1; choices[source.bundleIdentifier] = c
            }
            cursor = page.anchor; if page.empty { break }
        }
        return choices.values.sorted { $0.latestMs > $1.latestMs }
    }
    private static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970*1000).rounded()) }
    private static func source(_ sample: HKSample) -> Source {
        let device = sample.device
        let isWatch = device?.manufacturer == "Apple Inc." && device?.model?.lowercased().contains("watch") == true
        let zone = sample.metadata?[HKMetadataKeyTimeZone] as? String
        func limited(_ string: String?) -> String? { guard let string, !string.isEmpty else { return nil }; return String(string.prefix(120)) }
        return Source(bundleIdentifier:sample.sourceRevision.source.bundleIdentifier,sourceKey:sha256(sample.sourceRevision.source.bundleIdentifier),name:limited(sample.sourceRevision.source.name),deviceType:isWatch ? "watch" : nil,manufacturer:limited(device?.manufacturer),model:limited(device?.model),timeZone:zone.flatMap { TimeZone(identifier:$0) == nil ? nil : $0 })
    }
    private static func method(_ sample: HKSample, workout: Bool) -> String {
        if sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool == true { return "manual" }
        if sample.device != nil { return workout ? "active" : "automatic" }; return "unknown"
    }
    private static func sleep(_ sample: HKCategorySample) -> SleepSample {
        let value: String
        switch sample.value {
        case HKCategoryValueSleepAnalysis.inBed.rawValue: value="inBed"
        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: value="asleepUnspecified"
        case HKCategoryValueSleepAnalysis.awake.rawValue: value="awake"
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue: value="asleepCore"
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: value="asleepDeep"
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue: value="asleepREM"
        default: value="unknown:\(sample.value)"
        }
        return SleepSample(uuid:sample.uuid.uuidString.lowercased(),startMs:ms(sample.startDate),endMs:ms(sample.endDate),value:value,source:source(sample),recordingMethod:method(sample,workout:false))
    }
    private static func workout(_ w: HKWorkout) -> WorkoutSample {
        let distanceId: HKQuantityTypeIdentifier?
        switch w.workoutActivityType {
        case .walking,.running,.hiking: distanceId = .distanceWalkingRunning
        case .cycling: distanceId = .distanceCycling
        case .swimming: distanceId = .distanceSwimming
        case .wheelchairWalkPace,.wheelchairRunPace: distanceId = .distanceWheelchair
        default: distanceId = nil
        }
        let distance = distanceId.flatMap { w.statistics(for:HKQuantityType($0))?.sumQuantity()?.doubleValue(for:.meter()) } ?? w.totalDistance?.doubleValue(for:.meter())
        let energy = w.statistics(for:HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for:.kilocalorie()) ?? w.totalEnergyBurned?.doubleValue(for:.kilocalorie())
        let events = (w.workoutEvents ?? []).compactMap { e -> WorkoutEvent? in
            let name: String
            switch e.type { case .pause: name="pause"; case .resume: name="resume"; case .motionPaused:name="motionPaused"; case .motionResumed:name="motionResumed"; default:return nil }
            return WorkoutEvent(timeMs:ms(e.dateInterval.start),type:name)
        }
        let swim = (w.metadata?[HKMetadataKeySwimmingLocationType] as? NSNumber)?.intValue
        let location = swim == HKWorkoutSwimmingLocationType.pool.rawValue ? "pool" : swim == HKWorkoutSwimmingLocationType.openWater.rawValue ? "openWater" : nil
        return WorkoutSample(uuid:w.uuid.uuidString.lowercased(),startMs:ms(w.startDate),endMs:ms(w.endDate),durationMs:Int64((w.duration*1000).rounded()),activity:activityName(w.workoutActivityType),source:source(w),recordingMethod:method(w,workout:true),indoor:w.metadata?[HKMetadataKeyIndoorWorkout] as? Bool,swimmingLocation:location,distanceMetres:distance,activeKcal:energy,events:events)
    }
    private static func activityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .walking: return "walking"
        case .running: return "running"
        case .cycling: return "cycling"
        case .hiking: return "hiking"
        case .traditionalStrengthTraining: return "traditionalStrengthTraining"
        case .functionalStrengthTraining: return "functionalStrengthTraining"
        case .highIntensityIntervalTraining: return "highIntensityIntervalTraining"
        case .yoga: return "yoga"
        case .pilates: return "pilates"
        case .elliptical: return "elliptical"
        case .rowing: return "rowing"
        case .stairClimbing: return "stairClimbing"
        case .stairs: return "stairs"
        case .flexibility: return "flexibility"
        case .dance: return "dance"
        case .danceInspiredTraining: return "danceInspiredTraining"
        case .cardioDance: return "cardioDance"
        case .socialDance: return "socialDance"
        case .badminton: return "badminton"
        case .basketball: return "basketball"
        case .baseball: return "baseball"
        case .softball: return "softball"
        case .soccer: return "soccer"
        case .americanFootball: return "americanFootball"
        case .australianFootball: return "australianFootball"
        case .rugby: return "rugby"
        case .tennis: return "tennis"
        case .tableTennis: return "tableTennis"
        case .squash: return "squash"
        case .racquetball: return "racquetball"
        case .volleyball: return "volleyball"
        case .handball: return "handball"
        case .cricket: return "cricket"
        case .golf: return "golf"
        case .boxing: return "boxing"
        case .martialArts: return "martialArts"
        case .kickboxing: return "kickboxing"
        case .taiChi: return "taiChi"
        case .wrestling: return "wrestling"
        case .climbing: return "climbing"
        case .fencing: return "fencing"
        case .gymnastics: return "gymnastics"
        case .paddleSports: return "paddleSports"
        case .sailing: return "sailing"
        case .surfingSports: return "surfingSports"
        case .crossCountrySkiing: return "crossCountrySkiing"
        case .downhillSkiing: return "downhillSkiing"
        case .snowboarding: return "snowboarding"
        case .skatingSports: return "skatingSports"
        case .waterPolo: return "waterPolo"
        case .underwaterDiving: return "underwaterDiving"
        case .wheelchairWalkPace: return "wheelchairWalkPace"
        case .wheelchairRunPace: return "wheelchairRunPace"
        case .swimming: return "swimming"
        case .swimBikeRun: return "swimBikeRun"
        default: return "unknown:\(type.rawValue)"
        }
    }
}
