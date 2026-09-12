import XCTest
@testable import HealthRelay

@MainActor final class RecoveryTests:XCTestCase {
    func makeStore()throws->SyncStore{
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(newID()).appendingPathComponent("state.sqlite")
        return try SyncStore(url:url)
    }
    func sleep(_ uuid:String,_ start:Int64,_ end:Int64,value:String="asleepCore")->SleepSample{
        SleepSample(uuid:uuid,startMs:start,endMs:end,value:value,source:Source(bundleIdentifier:"test.watch",sourceKey:sha256("test.watch")),recordingMethod:"automatic")
    }
    func normalized(_ store:SyncStore,now:Int64)throws->[NormalizedEntity]{try Normalizer.sleep(store.list(SleepSample.self,"sleep"),dataset:store.dataset,now:now).entities}
    func testC28C29FixedHistoryAndRebuild()throws{
        let store=try makeStore();let first=try store.beginSync(now:10_000_000_000)
        XCTAssertEqual(try store.beginSync(now:20_000_000_000).historyStart,first.historyStart)
        let plan=RebuildPlan(planId:newID(),oldDatasetId:first.datasetId,newDatasetId:newID(),historyStart:first.historyStart!,sources:Sources(sleep:"test.watch"))
        try store.adoptRebuild(plan);XCTAssertEqual(try store.dataset.historyStart,first.historyStart)
        XCTAssertEqual(try store.dataset.datasetId,plan.newDatasetId)
        let reopened=try SyncStore(url:store.url);XCTAssertEqual(try reopened.dataset,try store.dataset)
    }
    func testC32SamePageDeleteWins()throws{
        let store=try makeStore();_ = try store.beginSync(now:10_000_000_000);try store.select(kind:"sleep",bundle:"test.watch")
        let id=newID(),sample=sleep(id,9_990_000_000,9_995_000_000)
        try store.ingest(HealthPage(sleep:[sample],workouts:[],deletions:[id],anchor:Data([1])),kind:"sleep")
        XCTAssertEqual(try store.list(SleepSample.self,"sleep").count,0)
        XCTAssertEqual(try store.get(Data.self,"anchor","sleep"),Data([1]))
    }
    func testC33AttemptedUnacknowledgedDeleteCompensates()throws{
        let store=try makeStore();let now:Int64=10_000_000_000;_ = try store.beginSync(now:now);try store.select(kind:"sleep",bundle:"test.watch")
        let id=newID();let page=HealthPage(sleep:[sleep(id,now-10_000_000,now-5_000_000)],workouts:[],deletions:[],anchor:Data())
        try store.ingest(page,kind:"sleep");try store.reconcile(normalized(store,now:now),kind:"sleep")
        let first=try XCTUnwrap(store.pending().first);try store.attempted(first)
        try store.ingest(HealthPage(sleep:[],workouts:[],deletions:[id],anchor:Data()),kind:"sleep")
        try store.reconcile([],kind:"sleep");let compensation=try XCTUnwrap(store.pending().first)
        XCTAssertEqual(compensation.group.changes[0].action,"delete")
        XCTAssertGreaterThan(compensation.group.changes[0].version,first.group.changes[0].version)
        XCTAssertEqual(compensation.group.changes[0].entityId,first.group.changes[0].entityId)
    }
    func testC05ConfirmedOldIdentitySurvivesCancelledUnsentRegroup()throws{
        let store=try makeStore();let now:Int64=10_000_000_000;_ = try store.beginSync(now:now);try store.select(kind:"sleep",bundle:"test.watch")
        let id=newID();try store.ingest(HealthPage(sleep:[sleep(id,now-10_000_000,now-5_000_000)],workouts:[],deletions:[],anchor:Data()),kind:"sleep")
        try store.reconcile(normalized(store,now:now),kind:"sleep");let original=try XCTUnwrap(store.pending().first);try store.attempted(original);try store.outcome(original,state:"completed")
        let earlier=newID();try store.ingest(HealthPage(sleep:[sleep(earlier,now-11_000_000,now-9_000_000)],workouts:[],deletions:[],anchor:Data()),kind:"sleep")
        try store.reconcile(normalized(store,now:now),kind:"sleep")
        try store.ingest(HealthPage(sleep:[],workouts:[],deletions:[id,earlier],anchor:Data()),kind:"sleep")
        try store.reconcile([],kind:"sleep")
        XCTAssertTrue(try store.pending().flatMap{$0.group.changes}.contains{$0.entityId==original.group.changes[0].entityId&&$0.action=="delete"})
    }
    func testC17C34MissingVisibilityRetainsDataAndHistoryFlag()throws{
        let store=try makeStore();let id=newID();try store.markVisibility(known:[id],visible:[])
        XCTAssertEqual(try store.list(String.self,"unavailable"),[id])
        XCTAssertTrue(try store.list(Int64.self,"tombstone").isEmpty)
        try store.put("meta","lastComplete","2026-09-01T00:00:00.000Z")
        XCTAssertEqual(try store.list(String.self,"unavailable"),[id])
        try store.markVisibility(known:[id],visible:[id]);XCTAssertTrue(try store.list(String.self,"unavailable").isEmpty)
    }
    func testC26DatabaseLostWithIdentityRequiresRecovery()throws{
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(newID()).appendingPathComponent("state.sqlite")
        let store=try SyncStore(url:url,priorIdentityExists:true)
        XCTAssertThrowsError(try store.beginSync(now:10000000000))
    }
    func testC01UnchangedContentDoesNotAllocateVersion()throws{
        let store=try makeStore();let now:Int64=10_000_000_000;_ = try store.beginSync(now:now);try store.select(kind:"sleep",bundle:"test.watch")
        try store.ingest(HealthPage(sleep:[sleep(newID(),now-10_000_000,now-5_000_000)],workouts:[],deletions:[],anchor:Data()),kind:"sleep")
        let entities=try normalized(store,now:now);try store.reconcile(entities,kind:"sleep");let item=try XCTUnwrap(store.pending().first)
        try store.outcome(item,state:"completed")
        for _ in 0..<2{try store.reconcile(entities,kind:"sleep")}
        XCTAssertTrue(try store.pending().isEmpty);XCTAssertEqual(try store.get(Int64.self,"meta","nextVersion"),2)
    }
    func testRegressionPendingRegroupReplaysSameRevision()throws{
        let store=try makeStore();let now:Int64=10_000_000_000
        _ = try store.beginSync(now:now);try store.select(kind:"sleep",bundle:"test.watch")
        let id=newID();try store.ingest(HealthPage(sleep:[sleep(id,now-10_000_000,now-5_000_000)],workouts:[],deletions:[],anchor:Data()),kind:"sleep")
        try store.reconcile(normalized(store,now:now),kind:"sleep")
        let confirmed=try XCTUnwrap(store.pending().first);try store.attempted(confirmed);try store.outcome(confirmed,state:"completed")
        let earlier=newID();try store.ingest(HealthPage(sleep:[sleep(earlier,now-11_000_000,now-9_000_000)],workouts:[],deletions:[],anchor:Data()),kind:"sleep")
        let target=try normalized(store,now:now);try store.reconcile(target,kind:"sleep")
        let pending=try XCTUnwrap(store.pending().first)
        let nextVersion=try store.get(Int64.self,"meta","nextVersion")
        for state in ["pending","retryable","partial"] {
            if state != "pending"{try store.attempted(pending)}
            try store.outcome(pending,state:state)
            let reopened=try SyncStore(url:store.url)
            try reopened.reconcile(target,kind:"sleep")
            XCTAssertEqual(try reopened.pending().first?.group,pending.group,"Lost receipts must replay the immutable revision, also after reopening SQLite")
            XCTAssertEqual(try reopened.get(Int64.self,"meta","nextVersion"),nextVersion)
        }
        let addition=sleep(newID(),now-5_000_000,now-4_000_000,value:"asleepREM")
        try store.ingest(HealthPage(sleep:[addition],workouts:[],deletions:[],anchor:Data()),kind:"sleep")
        try store.reconcile(normalized(store,now:now),kind:"sleep")
        let changed=try XCTUnwrap(store.pending().first)
        XCTAssertNotEqual(changed.group.changeSetId,pending.group.changeSetId)
        XCTAssertGreaterThan(changed.group.changes[0].version,pending.group.changes[0].version)
        XCTAssertTrue(changed.group.changes.contains{$0.entityId==confirmed.group.changes[0].entityId && $0.action=="delete"})
    }
    func synchronizeLocally(_ store:SyncStore,sleep additions:[SleepSample]=[],workouts:[WorkoutSample]=[],now:Int64?=nil) async throws {
        let reader=MemoryReader(sleep:additions,workouts:workouts)
        let coordinator=SyncCoordinator(store:store,reader:reader,lan:MemoryTransport(),readPairing:{nil},clock:{now ?? WireTime.now()})
        do{try await coordinator.synchronize(historical:false);XCTFail("The harness must stop at the unpaired boundary")}
        catch{XCTAssertEqual(error as? RelayError,.authentication)}
    }
    func confirmedSleep()throws->(SyncStore,Int64,SleepSample){
        let store=try makeStore();let now=WireTime.now();_ = try store.beginSync(now:now);try store.select(kind:"sleep",bundle:"test.watch")
        let sample=sleep(newID(),now-7_200_000,now-3_600_000)
        try store.ingest(HealthPage(sleep:[sample],workouts:[],deletions:[],anchor:Data()),kind:"sleep")
        try store.reconcile(normalized(store,now:now),kind:"sleep")
        let item=try XCTUnwrap(store.pending().first);try store.attempted(item);try store.outcome(item,state:"completed")
        return (store,now,sample)
    }
    func testRegressionControlNoNewInputKeepsConfirmedSleep() async throws {
        let (store,_,_)=try confirmedSleep();try await synchronizeLocally(store)
        XCTAssertTrue(try store.pending().isEmpty)
    }
    func testRegressionDeferredSleepMustNotDeleteConfirmedSession() async throws {
        let (store,now,_)=try confirmedSleep()
        let continuation=sleep(newID(),now-3_600_000,now-600_000)
        try await synchronizeLocally(store,sleep:[continuation],now:now)
        XCTAssertTrue(try store.pending().isEmpty,"Open group must not delete or send stale cached content")
        let reopened=try SyncStore(url:store.url)
        try await synchronizeLocally(reopened,now:now+1_800_000)
        let update=try XCTUnwrap(reopened.pending().first)
        XCTAssertEqual(update.group.changes.map(\.action),["upsert"])
        XCTAssertEqual(update.group.changes[0].payload?.end,WireTime.string(continuation.endMs))
        XCTAssertEqual(try reopened.get([String].self,"meta","deferredSleep"),[])
    }
    func testRegressionOversizedSleepMustNotDeleteConfirmedSession() async throws {
        let (store,now,_)=try confirmedSleep()
        try await synchronizeLocally(store,sleep:[sleep(newID(),now-140_000_000,now-3_600_000)])
        XCTAssertFalse(try store.pending().flatMap{$0.group.changes}.contains{$0.action=="delete"},"Rejecting an abnormal candidate is not an explicit source deletion")
    }
    func testRegressionInvalidWorkoutMustNotDeleteConfirmedSession() async throws {
        let store=try makeStore();let now=WireTime.now();_ = try store.beginSync(now:now);try store.select(kind:"workout",bundle:"test.watch")
        let source=Source(bundleIdentifier:"test.watch",sourceKey:sha256("test.watch"))
        var sample=WorkoutSample(uuid:newID(),startMs:now-7_200_000,endMs:now-3_600_000,durationMs:3_600_000,activity:"running",source:source,recordingMethod:"active",events:[])
        try store.ingest(HealthPage(sleep:[],workouts:[sample],deletions:[],anchor:Data()),kind:"workout")
        let normalized=try XCTUnwrap(Normalizer.workout(sample,dataset:store.dataset,now:now))
        try store.reconcile([normalized],kind:"workout")
        let item=try XCTUnwrap(store.pending().first);try store.attempted(item);try store.outcome(item,state:"completed")
        sample.durationMs=0
        try await synchronizeLocally(store,workouts:[sample])
        XCTAssertTrue(try store.pending().isEmpty,"Invalid content must not become deletion")
        XCTAssertEqual(try store.get(String.self,"error",sample.uuid),"INVALID_WORKOUT")
        sample.durationMs=3_000_000
        try await synchronizeLocally(store,workouts:[sample])
        XCTAssertEqual(try store.pending().first?.group.changes[0].action,"upsert")
        XCTAssertNil(try store.get(String.self,"error",sample.uuid))
    }
    func testEquivalentSourceRevisionReusesCanonicalPendingContent()throws {
        let store=try makeStore();let now=WireTime.now();_ = try store.beginSync(now:now);try store.select(kind:"sleep",bundle:"test.watch")
        var sample=sleep(newID(),now-7_200_000,now-3_600_000,value:"asleep")
        try store.ingest(HealthPage(sleep:[sample],workouts:[],deletions:[],anchor:Data()),kind:"sleep")
        try store.reconcile(normalized(store,now:now),kind:"sleep")
        let pending=try XCTUnwrap(store.pending().first);try store.attempted(pending)
        sample.value="asleepUnspecified"
        try store.ingest(HealthPage(sleep:[sample],workouts:[],deletions:[],anchor:Data()),kind:"sleep")
        try store.reconcile(normalized(store,now:now),kind:"sleep")
        XCTAssertEqual(try store.pending().first?.group,pending.group)
        XCTAssertEqual(try store.pending().first?.deliveryAttempted,true)
    }
    func testBlockedReplacementKeepsDeletedAnchorContextAcrossRestart() async throws {
        let (store,now,original)=try confirmedSleep()
        let abnormal=sleep(newID(),now-140_000_000,now-3_600_000)
        try store.ingest(HealthPage(sleep:[abnormal],workouts:[],deletions:[original.uuid],anchor:Data()),kind:"sleep")
        try await synchronizeLocally(store,now:now)
        XCTAssertTrue(try store.pending().isEmpty)
        let reopened=try SyncStore(url:store.url)
        try await synchronizeLocally(reopened,now:now)
        XCTAssertTrue(try reopened.pending().isEmpty,"Still-rejected replacement must keep the prior group protected on the next round")
        XCTAssertEqual(try reopened.list(NormalizedEntity.self,"remote").count,1)
        XCTAssertFalse(try reopened.list(String.self,"error").isEmpty)
        try reopened.ingest(HealthPage(sleep:[],workouts:[],deletions:[abnormal.uuid],anchor:Data()),kind:"sleep")
        try await synchronizeLocally(reopened,now:now)
        let deletion=try XCTUnwrap(reopened.pending().first)
        XCTAssertEqual(deletion.group.changes.map(\.action),["delete"])
        XCTAssertTrue(try reopened.list(String.self,"error").isEmpty)
        try reopened.outcome(deletion,state:"completed")
        XCTAssertTrue(try reopened.list(NormalizedEntity.self,"remote").isEmpty)
    }
    func testDeferredPendingGroupPausesWhileIndependentSleepProceeds() async throws {
        let store=try makeStore();let now=WireTime.now();_ = try store.beginSync(now:now);try store.select(kind:"sleep",bundle:"test.watch")
        let original=sleep(newID(),now-7_200_000,now-3_600_000)
        try store.ingest(HealthPage(sleep:[original],workouts:[],deletions:[],anchor:Data()),kind:"sleep")
        try store.reconcile(normalized(store,now:now),kind:"sleep")
        let attempted=try XCTUnwrap(store.pending().first);try store.attempted(attempted)
        let continuation=sleep(newID(),now-3_600_000,now-600_000)
        let independent=sleep(newID(),now-30_000_000,now-25_000_000)
        try await synchronizeLocally(store,sleep:[continuation,independent],now:now)
        XCTAssertEqual(try store.pending().flatMap{$0.group.changes}.map{$0.payload?.sampleUuids},[[independent.uuid]])
        XCTAssertEqual(try store.get(OutboxItem.self,"outbox",attempted.group.changeSetId)?.state,"superseded")
        try await synchronizeLocally(store,now:now+1_800_000)
        XCTAssertTrue(try store.pending().flatMap{$0.group.changes}.contains{$0.payload?.sampleUuids?.contains(continuation.uuid)==true})
    }
    func testInvalidSleepIntervalPreservesPriorSessionUntilCorrected() async throws {
        let (store,now,original)=try confirmedSleep();var invalid=original;invalid.endMs=invalid.startMs
        try await synchronizeLocally(store,sleep:[invalid],now:now)
        XCTAssertTrue(try store.pending().isEmpty)
        XCTAssertEqual(try store.get(String.self,"error","sleep:"+original.uuid),"INVALID_INTERVAL")
        invalid.endMs=original.endMs-60_000
        try await synchronizeLocally(store,sleep:[invalid],now:now)
        XCTAssertEqual(try store.pending().first?.group.changes.map(\.action),["upsert"])
        XCTAssertTrue(try store.list(String.self,"error").isEmpty)
    }
    func testFutureWorkoutDoesNotDeletePriorSession() async throws {
        let store=try makeStore();let now=WireTime.now();_ = try store.beginSync(now:now);try store.select(kind:"workout",bundle:"test.watch")
        let source=Source(bundleIdentifier:"test.watch",sourceKey:sha256("test.watch"))
        var sample=WorkoutSample(uuid:newID(),startMs:now-7_200_000,endMs:now-3_600_000,durationMs:3_600_000,activity:"running",source:source,recordingMethod:"active",events:[])
        try store.ingest(HealthPage(sleep:[],workouts:[sample],deletions:[],anchor:Data()),kind:"workout")
        try store.reconcile([XCTUnwrap(Normalizer.workout(sample,dataset:store.dataset,now:now))],kind:"workout")
        try store.outcome(XCTUnwrap(store.pending().first),state:"completed")
        sample.endMs=now+600_000;sample.durationMs=sample.endMs-sample.startMs
        try await synchronizeLocally(store,workouts:[sample],now:now)
        XCTAssertTrue(try store.pending().isEmpty)
        try await synchronizeLocally(store,workouts:[sample],now:now+1_800_000)
        XCTAssertEqual(try store.pending().first?.group.changes.map(\.action),["upsert"])
    }
    func testRegressionUnacknowledgedIdentitySurvivesUnsentRegroup()throws{
        let store=try makeStore();let now:Int64=10_000_000_000
        _ = try store.beginSync(now:now);try store.select(kind:"sleep",bundle:"test.watch")
        let firstID=newID();try store.ingest(HealthPage(sleep:[sleep(firstID,now-10_000_000,now-5_000_000)],workouts:[],deletions:[],anchor:Data()),kind:"sleep")
        try store.reconcile(normalized(store,now:now),kind:"sleep")
        let attempted=try XCTUnwrap(store.pending().first);try store.attempted(attempted)
        let earlier=newID();try store.ingest(HealthPage(sleep:[sleep(earlier,now-11_000_000,now-9_000_000)],workouts:[],deletions:[],anchor:Data()),kind:"sleep")
        try store.reconcile(normalized(store,now:now),kind:"sleep")
        try store.ingest(HealthPage(sleep:[],workouts:[],deletions:[firstID,earlier],anchor:Data()),kind:"sleep")
        try store.reconcile([],kind:"sleep")
        XCTAssertTrue(try store.pending().flatMap{$0.group.changes}.contains{$0.entityId==attempted.group.changes[0].entityId&&$0.action=="delete"},"The first identity may exist remotely even though its replacement was never sent")
    }
    func testRegressionUnreadablePendingPayloadNeverCrossesTransport() async throws {
        let store=try makeStore();let now=WireTime.now();_ = try store.beginSync(now:now);try store.select(kind:"sleep",bundle:"test.watch")
        let sample=sleep(newID(),now-7_200_000,now-3_600_000)
        try store.ingest(HealthPage(sleep:[sample],workouts:[],deletions:[],anchor:Data()),kind:"sleep")
        try store.reconcile(normalized(store,now:now),kind:"sleep")
        let reader=MemoryReader()
        let transport=MemoryTransport()
        let pair=Pairing(receiverId:newID(),certificateFingerprint:String(repeating:"0",count:64),pairId:newID(),pairToken:"synthetic-only",senderId:newID(),mode:"normal",ip:"127.0.0.1",port:1)
        let coordinator=SyncCoordinator(store:store,reader:reader,lan:transport,readPairing:{pair})
        try await coordinator.synchronize(historical:false)
        XCTAssertEqual(transport.healthFrames,0,"Cached health values must not cross the transport when all dependency UUIDs are unreadable")
        XCTAssertEqual(try store.pending().first?.state,"SOURCE_RECORD_UNAVAILABLE")
        reader.visibleSleep=[sample]
        try await coordinator.synchronize(historical:false)
        XCTAssertEqual(transport.healthFrames,1)
        XCTAssertTrue(try store.pending().isEmpty)
    }
}

@MainActor private final class MemoryReader:HealthReading {
    var additions:[SleepSample];var workouts:[WorkoutSample];var visibleSleep:[SleepSample]
    private var delivered=Set<String>()
    init(sleep:[SleepSample]=[],workouts:[WorkoutSample]=[]){self.additions=sleep;self.workouts=workouts;self.visibleSleep=sleep}
    func authorize() async throws {}
    func sources(kind:String,lowerMs:Int64) async throws -> [SourceChoice]{[]}
    func page(kind:String,lowerMs:Int64,anchorData:Data?) async throws -> HealthPage {
        let first=delivered.insert(kind).inserted
        return HealthPage(sleep:first && kind=="sleep" ? additions:[],workouts:first && kind=="workout" ? workouts:[],deletions:[],anchor:Data([first ? 1:2]))
    }
    func readUUIDs(kind:String,uuids:[String]) async throws -> HealthPage {
        HealthPage(sleep:kind=="sleep" ? visibleSleep.filter{uuids.contains($0.uuid)}:[],workouts:kind=="workout" ? workouts.filter{uuids.contains($0.uuid)}:[],deletions:[],anchor:Data())
    }
}
@MainActor private final class MemoryTransport:RelayTransport {
    var healthFrames=0;var connections=0
    func close(){}
    func connect(_ pairing:Pairing,manual:(String,UInt16)?) async throws {connections += 1}
    func hello(_ pairing:Pairing,dataset:Dataset) async throws -> [String:Any]{[:]}
    func pair(_ code:PairingCode,dataset:Dataset,mode:String,senderId:String) async throws -> ([String:Any],Pairing){throw RelayError.authentication}
    func request(type:String,fields:[String:Any]) async throws -> [String:Any] {
        guard type=="applyBatch" else{return [:]}
        healthFrames += 1
        let groups=try WireCodec.decode([ChangeSet].self,JSONSerialization.data(withJSONObject:fields["changeSets"]!))
        return ["generationId":fields["generationId"]!,"batchId":fields["batchId"]!,"changeSets":groups.map{group in
            ["changeSetId":group.changeSetId,"entities":group.changes.map{["entityId":$0.entityId,"version":$0.version,"status":"applied","children":["session":"applied"]] as [String:Any]}] as [String:Any]
        }]
    }
}


extension RecoveryTests {
    func testRepeatedRebuildAdoptionPreservesLedgerAndVersionsAfterRestart() throws {
        let (store,now,_)=try confirmedSleep();let old=try store.dataset
        let plan=RebuildPlan(planId:newID(),oldDatasetId:old.datasetId,newDatasetId:newID(),historyStart:old.historyStart!,sources:old.sources)
        try store.adoptRebuild(plan)
        let sample=sleep(newID(),now-7_200_000,now-3_600_000)
        try store.ingest(HealthPage(sleep:[sample],workouts:[],deletions:[],anchor:Data()),kind:"sleep")
        try store.reconcile(normalized(store,now:now),kind:"sleep")
        try store.outcome(XCTUnwrap(store.pending().first),state:"completed")
        let remote=try store.list(NormalizedEntity.self,"remote")
        let version=try store.get(Int64.self,"meta","nextVersion")
        let reopened=try SyncStore(url:store.url)
        try reopened.adoptRebuild(plan)
        XCTAssertEqual(try reopened.list(NormalizedEntity.self,"remote"),remote)
        XCTAssertEqual(try reopened.get(Int64.self,"meta","nextVersion"),version)
        XCTAssertEqual(try reopened.list(SleepSample.self,"sleep"),[sample])
        var wrong=plan;wrong.planId=newID()
        XCTAssertThrowsError(try reopened.adoptRebuild(wrong))
        XCTAssertEqual(try reopened.get(Int64.self,"meta","nextVersion"),version)
    }
    func testRebuildRejectsUnrelatedOldDatasetWithoutClearing() throws {
        let (store,_,_)=try confirmedSleep();let dataset=try store.dataset
        let plan=RebuildPlan(planId:newID(),oldDatasetId:newID(),newDatasetId:newID(),historyStart:dataset.historyStart!,sources:dataset.sources)
        XCTAssertThrowsError(try store.adoptRebuild(plan))
        XCTAssertEqual(try store.dataset,dataset)
        XCTAssertEqual(try store.list(NormalizedEntity.self,"remote").count,1)
    }
    func testSampleLimitBlocksOnlyAffectedSleepAndRecovers() async throws {
        let (store,now,original)=try confirmedSleep()
        let overflow=(0..<10000).map{_ in sleep(newID(),original.startMs,original.endMs)}
        let independent=sleep(newID(),now-30_000_000,now-25_000_000)
        try await synchronizeLocally(store,sleep:overflow+[independent],now:now)
        XCTAssertEqual(try store.pending().flatMap{$0.group.changes}.map{$0.payload?.sampleUuids},[[independent.uuid]])
        XCTAssertEqual(try store.list(NormalizedEntity.self,"remote").count,1)
        XCTAssertEqual(try store.get(String.self,"error","sleep:"+original.uuid),"SLEEP_GROUP_TOO_LARGE")
        let reopened=try SyncStore(url:store.url)
        try reopened.ingest(HealthPage(sleep:[],workouts:[],deletions:overflow.map(\.uuid),anchor:Data()),kind:"sleep")
        try await synchronizeLocally(reopened,now:now)
        XCTAssertTrue(try reopened.list(String.self,"error").isEmpty)
        XCTAssertFalse(try reopened.pending().flatMap{$0.group.changes}.contains{$0.action=="delete"})
    }
    func testInvalidGroupDoesNotAbortIndependentChanges() throws {
        let (store,now,_)=try confirmedSleep()
        let original=try XCTUnwrap(store.list(NormalizedEntity.self,"remote").first)
        var invalid=original;invalid.payload.recordingMethod="invalid"
        let independent=try XCTUnwrap(Normalizer.sleep([sleep(newID(),now-30_000_000,now-25_000_000)],dataset:store.dataset,now:now).entities.first)
        try store.reconcile([invalid,independent],kind:"sleep")
        XCTAssertEqual(try store.pending().flatMap{$0.group.changes}.map(\.entityId),[independent.entityId])
        XCTAssertEqual(try store.list(NormalizedEntity.self,"remote"),[original])
        XCTAssertFalse(try store.list(String.self,"error").isEmpty)
        var corrected=original;corrected.payload.recordingMethod="manual"
        try store.reconcile([corrected,independent],kind:"sleep")
        XCTAssertTrue(try store.list(String.self,"error").isEmpty)
        XCTAssertTrue(try store.pending().flatMap{$0.group.changes}.contains{$0.entityId==original.entityId && $0.payload?.recordingMethod=="manual"})
    }
    func testRejectedReplacementKeepsOldAnchorUntilCorrectedAcrossRestart() async throws {
        let (store,now,original)=try confirmedSleep()
        var replacement=sleep(newID(),original.startMs,original.endMs);replacement.source.name=" "
        try store.ingest(HealthPage(sleep:[replacement],workouts:[],deletions:[original.uuid],anchor:Data()),kind:"sleep")
        try await synchronizeLocally(store,now:now)
        XCTAssertTrue(try store.pending().isEmpty,"A rejected replacement must not send the old anchor deletion")
        let reopened=try SyncStore(url:store.url)
        try await synchronizeLocally(reopened,now:now)
        XCTAssertTrue(try reopened.pending().isEmpty)
        XCTAssertFalse(try reopened.list(String.self,"error").isEmpty)
        replacement.source.name="Synthetic Watch"
        try await synchronizeLocally(reopened,sleep:[replacement],now:now)
        XCTAssertEqual(try reopened.pending().count,1,"Old-anchor deletion and replacement must form one revision group")
        let changes=try reopened.pending().flatMap{$0.group.changes}
        XCTAssertTrue(changes.contains{$0.action=="delete" && $0.entityId.contains(original.uuid)})
        XCTAssertTrue(changes.contains{$0.action=="upsert" && $0.payload?.sampleUuids==[replacement.uuid]})
        XCTAssertTrue(try reopened.list(String.self,"error").isEmpty)
    }
    func testDeletingNeverImportedRejectedSleepClearsItsError() async throws {
        let store=try makeStore();let now=WireTime.now();try store.select(kind:"sleep",bundle:"test.watch")
        var invalid=sleep(newID(),now-7_200_000,now-3_600_000);invalid.source.name=" "
        try await synchronizeLocally(store,sleep:[invalid],now:now)
        XCTAssertFalse(try store.list(String.self,"error").isEmpty)
        try store.ingest(HealthPage(sleep:[],workouts:[],deletions:[invalid.uuid],anchor:Data()),kind:"sleep")
        try await synchronizeLocally(store,now:now)
        XCTAssertTrue(try store.list(String.self,"error").isEmpty)
        XCTAssertTrue(try store.pending().isEmpty)
    }
    func testStopWaitsForCancelledReadBeforeAllowingRetry() async throws {
        let store=try makeStore();try store.select(kind:"sleep",bundle:"test.watch")
        let reader=SuspendedReader();let transport=MemoryTransport()
        let pair=Pairing(receiverId:newID(),certificateFingerprint:String(repeating:"0",count:64),pairId:newID(),pairToken:"synthetic-only",senderId:newID(),mode:"normal",ip:"127.0.0.1",port:1)
        let coordinator=SyncCoordinator(store:store,reader:reader,lan:transport,readPairing:{pair})
        coordinator.run();let old=try XCTUnwrap(coordinator.task)
        await fulfillment(of:[reader.entered],timeout:3)
        coordinator.stop()
        XCTAssertTrue(coordinator.busy,"An unfinished cancelled task still owns the transport")
        coordinator.run()
        reader.release();await old.value
        XCTAssertEqual(transport.connections,0,"Cancellation must propagate before connect")
        XCTAssertFalse(coordinator.busy)
        coordinator.run();await coordinator.task?.value
        XCTAssertEqual(transport.connections,1,"A new manual retry succeeds after cancellation settles")
    }
}

@MainActor private final class SuspendedReader:HealthReading {
    let entered=XCTestExpectation(description:"Health query suspended")
    private var continuation:CheckedContinuation<Void,Never>?
    private var first=true
    func release(){continuation?.resume();continuation=nil}
    func authorize() async throws {}
    func sources(kind:String,lowerMs:Int64) async throws -> [SourceChoice]{[]}
    func page(kind:String,lowerMs:Int64,anchorData:Data?) async throws -> HealthPage {
        if first {first=false;await withCheckedContinuation{continuation=$0;entered.fulfill()}}
        return HealthPage(sleep:[],workouts:[],deletions:[],anchor:Data())
    }
    func readUUIDs(kind:String,uuids:[String]) async throws -> HealthPage {HealthPage(sleep:[],workouts:[],deletions:[],anchor:Data())}
}
