import Foundation

@MainActor protocol HealthReading {
    func authorize() async throws
    func sources(kind:String,lowerMs:Int64) async throws -> [SourceChoice]
    func page(kind:String,lowerMs:Int64,anchorData:Data?) async throws -> HealthPage
    func readUUIDs(kind:String,uuids:[String]) async throws -> HealthPage
}
extension HealthKitReader: HealthReading {}

@MainActor protocol RelayTransport {
    func close()
    func connect(_ pairing:Pairing,manual:(String,UInt16)?) async throws
    func hello(_ pairing:Pairing,dataset:Dataset) async throws -> [String:Any]
    func request(type:String,fields:[String:Any]) async throws -> [String:Any]
    func pair(_ code:PairingCode,dataset:Dataset,mode:String,senderId:String) async throws -> ([String:Any],Pairing)
}
extension LANClient: RelayTransport {}

@MainActor final class SyncCoordinator {
    let store:SyncStore;let reader:any HealthReading;let lan:any RelayTransport
    private let readPairing:() throws -> Pairing?
    private let clock:() -> Int64
    var onUpdate:(()->Void)?
    var status="准备同步";var details:[String]=[];var busy=false
    var manualAddress:(String,UInt16)?
    var task:Task<Void,Never>?
    init(store:SyncStore,reader:any HealthReading=HealthKitReader(),lan:any RelayTransport=LANClient(),
         readPairing:@escaping () throws -> Pairing? = {try PairingVault.read(Pairing.self,key:"pairing")},
         clock:@escaping () -> Int64 = WireTime.now){
        self.store=store;self.reader=reader;self.lan=lan;self.readPairing=readPairing;self.clock=clock
    }
    func update(_ text:String){status=text;onUpdate?()}
    func stop(){task?.cancel();lan.close();update(busy ? "正在停止同步，请稍候":"同步中断，可重试")}
    func run(historical:Bool=false){
        guard !busy else{return};busy=true
        task=Task{
            defer{busy=false;task=nil;lan.close();onUpdate?()}
            do{try await synchronize(historical:historical)}catch is CancellationError{update("同步中断，可重试")}catch{update((error as? RelayError)?.rawValue ?? "读取或连接失败，请检查权限与网络")}
        }
    }
    private func ingest(kind:String,dataset:Dataset,full:Bool) async throws {
        guard (kind=="sleep" ? dataset.sources.sleep:dataset.sources.workout) != nil else{return}
        let lower=try WireTime.milliseconds(dataset.historyStart!)-(kind=="sleep" ? 48*60*60*1000:0)
        var anchor=full ? nil:try store.get(Data.self,"anchor",kind)
        var visible=Set<String>();var restarted=false
        let known:Set<String>=kind=="sleep" ? Set(try store.list(SleepSample.self,kind).map(\.uuid)):Set(try store.list(WorkoutSample.self,kind).map(\.uuid))
        while true{
            try Task.checkCancellation()
            let page:HealthPage
            do{page=try await reader.page(kind:kind,lowerMs:lower,anchorData:anchor)}catch{
                try Task.checkCancellation();if error is CancellationError{throw error}
                if anchor != nil && !restarted{anchor=nil;restarted=true;details.append("游标不可用，按固定起点重新读取；历史删除可能遗漏");continue};throw error
            }
            try Task.checkCancellation()
            try store.ingest(page,kind:kind);anchor=page.anchor
            visible.formUnion(page.sleep.filter{$0.source.bundleIdentifier==dataset.sources.sleep}.map(\.uuid))
            visible.formUnion(page.workouts.filter{$0.source.bundleIdentifier==dataset.sources.workout}.map(\.uuid))
            update("正在读取\(kind=="sleep" ? "睡眠":"运动") · \(visible.count) 条")
            if page.empty{break}
        }
        if full||restarted{try store.markVisibility(known:known,visible:visible)}
    }
    func refreshWorkouts() async throws {
        let workouts=try store.list(WorkoutSample.self,"workout");var visible=Set<String>()
        for start in stride(from:0,to:workouts.count,by:100){
            let ids=workouts[start..<min(start+100,workouts.count)].map(\.uuid)
            try Task.checkCancellation()
            let page=try await reader.readUUIDs(kind:"workout",uuids:ids)
            try Task.checkCancellation()
            visible.formUnion(page.workouts.map(\.uuid));try store.ingest(page,kind:"workout")
        }
        try store.markVisibility(known:Set(workouts.map(\.uuid)),visible:visible)
    }
    private func validateVisibility(_ item:OutboxItem) async throws {
        for kind in ["sleep","workout"]{
            let ids=Array(Set(item.group.changes.filter{$0.kind==kind}.flatMap{$0.payload?.dependencies ?? []})).sorted()
            var visible=Set<String>()
            for start in stride(from:0,to:ids.count,by:100){
                try Task.checkCancellation()
                let page=try await reader.readUUIDs(kind:kind,uuids:Array(ids[start..<min(start+100,ids.count)]))
                try Task.checkCancellation()
                visible.formUnion(page.sleep.map(\.uuid));visible.formUnion(page.workouts.map(\.uuid))
            }
            try store.markVisibility(known:Set(ids),visible:visible)
            guard Set(ids).isSubset(of:visible) else{throw RelayError.unavailable}
        }
    }
    private func connect(pairing:Pairing,dataset:Dataset) async throws {
        try Task.checkCancellation()
        try await lan.connect(pairing,manual:manualAddress);try Task.checkCancellation()
        let result=try await lan.hello(pairing,dataset:dataset);try Task.checkCancellation()
        if let recovery=result["recoveryInfo"] as? [String:Any]{try store.put("meta","receiverRecovery",JSONSerialization.data(withJSONObject:recovery))}
    }
    func synchronize(historical:Bool) async throws {
        try Task.checkCancellation()
        details=[];let now=clock();let dataset=try store.beginSync(now:now)
        guard dataset.sources.sleep != nil || dataset.sources.workout != nil else{throw RelayError.source}
        var readableKinds=Set<String>()
        for kind in ["sleep","workout"]{
            do{try await ingest(kind:kind,dataset:dataset,full:historical);readableKinds.insert(kind)}catch{try Task.checkCancellation();if error is CancellationError{throw error};details.append("\(kind)：读取失败；该类暂停发送")}
        }
        if readableKinds.contains("workout"){do{try await refreshWorkouts()}catch{try Task.checkCancellation();if error is CancellationError{throw error};readableKinds.remove("workout");details.append("运动汇总重读失败")}}
        if readableKinds.contains("sleep"){
            let cached=try store.list(SleepSample.self,"sleep")
            let previous=try store.list(SleepSample.self,"affectedSleep")
            let dirty=Set(try store.list(String.self,"dirtyUUID"))
            let deferred=Set(try store.get([String].self,"meta","deferredSleep") ?? [])
            let affected=Normalizer.affectedSleepUUIDs(cached+previous,seeds:dirty.union(deferred))
            let normalized=try Normalizer.sleep(cached,dataset:dataset,now:now,affectedUUIDs:affected)
            let retained=try store.list(StoredEntity.self,"entity").filter{$0.entity.kind=="sleep" && $0.entity.payload.dependencies.isDisjoint(with:affected)}.map(\.entity)
            var blocked=Normalizer.affectedSleepUUIDs(cached+previous,seeds:normalized.deferred.union(normalized.rejected.keys))
            for id in affected{try store.remove("error","reconcile:"+id)}
            blocked.formUnion(try store.reconcile(retained+normalized.entities,kind:"sleep",blockedUUIDs:blocked,
                relatedDependencies:{Normalizer.affectedSleepUUIDs(cached+previous,seeds:$0)}))
            try store.transaction {
                for id in dirty where !blocked.contains(id){try store.remove("dirtyUUID",id);try store.remove("affectedSleep",id)}
                // Re-evaluate blocked components even when HealthKit supplies no new anchor changes.
                try store.put("meta","deferredSleep",Array(blocked).sorted())
                for id in affected {try store.remove("error","sleep:"+id)}
                for (id,error) in normalized.rejected {try store.put("error","sleep:"+id,error)}
            }
            details.append("\(normalized.candidateCount) 组源睡眠 → \(normalized.entities.count) 条会话；空档或冲突未导入 \(normalized.excludedMilliseconds) 毫秒")
            details.append(contentsOf:normalized.warnings)
        }
        if readableKinds.contains("workout"){
            let samples=try store.list(WorkoutSample.self,"workout");var entities:[NormalizedEntity]=[];var blocked=Set<String>()
            for sample in samples{
                do{try store.remove("error",sample.uuid);if var entity=try Normalizer.workout(sample,dataset:dataset,now:now){
                    if samples.contains(where:{$0.uuid != sample.uuid && $0.startMs<sample.endMs && $0.endMs>sample.startMs}){entity.payload.warnings.append("OVERLAPPING_WORKOUTS")}
                    entities.append(entity)
                }else{blocked.insert(sample.uuid)}}catch{blocked.insert(sample.uuid);try store.put("error",sample.uuid,"INVALID_WORKOUT");details.append("无效运动已跳过")}
            }
            try store.reconcile(entities,kind:"workout",blockedUUIDs:blocked)
        }
        guard let pairing=try readPairing(),pairing.mode=="normal" else{throw RelayError.authentication}
        try await connect(pairing:pairing,dataset:dataset)
        let generation=newID();var applied=0;var partial=0
        let remoteIDs=Set(try store.list(NormalizedEntity.self,"remote").map(\.entityId))
        var summary:[String:[String:Int]]=[:]
        func count(_ kind:String,_ outcome:String,_ amount:Int=1){summary[kind,default:[:]][outcome,default:0]+=amount}
        for item in try store.list(StoredEntity.self,"entity") where item.confirmed{count(item.entity.kind,"未变化")}

        for item in try store.pending(){
            try Task.checkCancellation()
            guard item.group.changes.allSatisfy({readableKinds.contains($0.kind)}) else{continue}
            var finished=false
            for attempt in 0..<4{
                do{
                    try await validateVisibility(item)
                    try Task.checkCancellation()
                    // Durable possible-delivery marker precedes the first byte sent.
                    try store.attempted(item)
                    update("正在传输 · 已处理 \(applied) 条")
                    let batchId=newID()
                    let groups=try JSONSerialization.jsonObject(with:WireCodec.encode([item.group]))
                    let result=try await lan.request(type:"applyBatch",fields:["generationId":generation,"batchId":batchId,"changeSets":groups])
                    try Task.checkCancellation()
                    guard result["generationId"] as? String==generation,result["batchId"] as? String==batchId,
                          let groups=result["changeSets"] as? [[String:Any]],groups.count==1,groups[0]["changeSetId"] as? String==item.group.changeSetId else{throw RelayError.invalidPayload}
                    if let error=groups[0]["error"] as? String{
                        try store.outcome(item,state:["INVALID_PAYLOAD","VERSION_CONFLICT"].contains(error) ? "rejected":"retryable",error:error);partial += 1;details.append(error);finished=true;break
                    }
                    guard let entities=groups[0]["entities"] as? [[String:Any]],Set(entities.compactMap{$0["entityId"] as? String})==Set(item.group.changes.map(\.entityId)) else{throw RelayError.invalidPayload}
                    for entity in entities{
                        let original=item.group.changes.first{$0.entityId==entity["entityId"] as? String}!
                        guard (entity["version"] as? NSNumber)?.int64Value==original.version else{throw RelayError.invalidPayload}
                    }
                    let complete=entities.allSatisfy{["applied","unchanged","superseded"].contains($0["status"] as? String ?? "")}
                    try store.outcome(item,state:complete ? "completed":"partial")
                    if complete{
                        applied += entities.count
                        for change in item.group.changes {
                            count(change.kind,item.deliveryAttempted ? "重试已确认" : change.action=="delete" ? "删除" : remoteIDs.contains(change.entityId) ? "更新":"新增")
                        }
                    }else{partial += 1;for change in item.group.changes{count(change.kind,"部分完成")}}
                    for entity in entities {
                        if let children=entity["children"] as? [String:String]{
                            for (field,state) in children where state != "applied" {details.append("\(field)：\(state)")}
                        }
                    }
                    for c in item.group.changes{if c.kind=="workout",let p=c.payload{details.append(contentsOf:p.warnings);details.append("Apple Health 运动时长：\(p.durationMs ?? 0) 毫秒；活动能量只写入 Health Connect")}}
                    finished=true;break
                }catch is CancellationError{throw CancellationError()}catch RelayError.unavailable{try store.outcome(item,state:"SOURCE_RECORD_UNAVAILABLE",error:"SOURCE_RECORD_UNAVAILABLE");partial += 1;finished=true;break}
                catch{
                    try Task.checkCancellation()
                    if attempt<3 && (error as? RelayError)==RelayError.network{
                        try await Task.sleep(for:.seconds([1,2,4][attempt]));try await connect(pairing:pairing,dataset:dataset)
                    }else{try store.outcome(item,state:"retryable",error:(error as? RelayError)?.rawValue);partial += 1;finished=true;break}
                }
            }
            if !finished{partial += 1}
        }
        try Task.checkCancellation()
        _ = try await lan.request(type:"finish",fields:["generationId":generation])
        try Task.checkCancellation()
        let pending=try store.pending().count;let errors=try store.list(String.self,"error").count
        let rejected=try store.list(OutboxItem.self,"outbox").filter{$0.state=="rejected"}.count
        if partial==0&&pending==0&&errors==0&&rejected==0&&readableKinds.count==2{try store.put("meta","lastComplete",WireTime.string(WireTime.now()))}
        let unavailable=try store.list(String.self,"unavailable").count
        for kind in ["sleep","workout"]{
            let values=summary[kind] ?? [:]
            details.append("\(kind=="sleep" ? "睡眠":"运动")："+["新增","更新","删除","未变化","重试已确认","部分完成"].map{"\($0) \(values[$0,default:0])"}.joined(separator:"，"))
        }
        details.append("历史待核对：\(unavailable) 条。历史删除仅按实际收到的事件处理，可能存在遗漏。")
        try store.put("meta","resultDetails",Array(details.suffix(200)))
        update(partial>0||pending>0||errors>0||rejected>0 ? "部分完成 · \(applied) 条已处理，\(pending) 组待重试" : applied==0 ? (summary.values.contains{$0["未变化",default:0]>0} ? "本轮未变化；历史状态请查看详情":"没有可读取的新数据；请核对权限与来源") : "已写入 Health Connect，请到三星健康查看")
    }
}
