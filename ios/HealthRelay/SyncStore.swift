import Foundation
import SQLite3

struct OutboxItem: Codable, Sendable {
    var group: ChangeSet; var deliveryAttempted: Bool; var state: String; var error: String?
    var dependencies: Set<String> { Set(group.changes.flatMap { $0.payload?.dependencies ?? [] }) }
}
struct StoredEntity: Codable, Sendable { var entity: NormalizedEntity; var version: Int64; var confirmed: Bool }

// All access is confined to the main actor. Health reads and socket I/O suspend off it.
@MainActor final class SyncStore {
    private var db: OpaquePointer?
    let url: URL
    init(url: URL, priorIdentityExists: Bool = false) throws {
        self.url = url
        let existed = FileManager.default.fileExists(atPath:url.path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
        var protected = directory; var values=URLResourceValues(); values.isExcludedFromBackup=true; try protected.setResourceValues(values)
        guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else { throw RelayError.storage }
        try execute("PRAGMA journal_mode=WAL"); try execute("PRAGMA synchronous=FULL")
        try execute("CREATE TABLE IF NOT EXISTS state (bucket TEXT NOT NULL, key TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY(bucket,key))")
        try execute("PRAGMA user_version=1")
        if !existed && priorIdentityExists { try put("meta","recovery",true) }
        let check=try statement("PRAGMA quick_check");defer{sqlite3_finalize(check)}
        guard sqlite3_step(check)==SQLITE_ROW,let text=sqlite3_column_text(check,0),String(cString:text)=="ok" else{throw RelayError.recovery}
        if try get(Dataset.self,"meta","dataset") == nil {
            try put("meta","dataset",Dataset(datasetId:newID(),sources:Sources()))
            try put("meta","nextVersion",Int64(1))
        }
        try protectFiles()
    }
    isolated deinit {sqlite3_close(db)}
    func protectFiles() throws {
        for suffix in ["","-wal","-shm"] {
            let path=url.path+suffix
            if FileManager.default.fileExists(atPath:path) { try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:path); var file=URL(fileURLWithPath:path); var v=URLResourceValues();v.isExcludedFromBackup=true;try file.setResourceValues(v) }
        }
    }
    private func execute(_ sql: String) throws { guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else { throw RelayError.storage } }
    private func statement(_ sql: String, _ parameters: [String] = []) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK, let stmt else { throw RelayError.storage }
        for (i,p) in parameters.enumerated() { _ = p.withCString { sqlite3_bind_text(stmt,Int32(i+1),$0,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)) } }
        return stmt
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result=try body();try execute("COMMIT");return result } catch { try? execute("ROLLBACK");throw error }
    }
    func put<T:Encodable>(_ bucket:String,_ key:String,_ value:T) throws {
        let data=try WireCodec.encode(value), s=try statement("INSERT OR REPLACE INTO state(bucket,key,value) VALUES(?,?,?)",[bucket,key]);defer{sqlite3_finalize(s)}
        _ = data.withUnsafeBytes { sqlite3_bind_blob(s,3,$0.baseAddress,Int32(data.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }
        guard sqlite3_step(s)==SQLITE_DONE else { throw RelayError.storage }
    }
    func get<T:Decodable>(_ type:T.Type,_ bucket:String,_ key:String) throws -> T? {
        let s=try statement("SELECT value FROM state WHERE bucket=? AND key=?",[bucket,key]);defer{sqlite3_finalize(s)}
        let status=sqlite3_step(s)
        guard status==SQLITE_ROW || status==SQLITE_DONE else{throw RelayError.storage}
        if status==SQLITE_ROW { let data=Data(bytes:sqlite3_column_blob(s,0),count:Int(sqlite3_column_bytes(s,0)));return try WireCodec.decode(type,data) };return nil
    }
    func list<T:Decodable>(_ type:T.Type,_ bucket:String) throws -> [T] {
        let s=try statement("SELECT value FROM state WHERE bucket=? ORDER BY key",[bucket]);defer{sqlite3_finalize(s)};var result:[T]=[]
        while true {
            let status=sqlite3_step(s)
            if status==SQLITE_DONE{return result}
            guard status==SQLITE_ROW else{throw RelayError.storage}
            result.append(try WireCodec.decode(type,Data(bytes:sqlite3_column_blob(s,0),count:Int(sqlite3_column_bytes(s,0)))))
        }
    }
    func remove(_ bucket:String,_ key:String) throws {
        let s=try statement("DELETE FROM state WHERE bucket=? AND key=?",[bucket,key]);defer{sqlite3_finalize(s)};guard sqlite3_step(s)==SQLITE_DONE else{throw RelayError.storage}
    }
    var dataset: Dataset { get throws { guard let d=try get(Dataset.self,"meta","dataset") else{throw RelayError.recovery};return d } }
    func beginSync(now:Int64) throws -> Dataset {
        guard try get(Bool.self,"meta","recovery") != true else { throw RelayError.recovery }
        return try transaction {
            var d=try dataset
            if d.historyStart == nil { d.historyStart=WireTime.string(now-30*24*60*60*1000);try put("meta","dataset",d) }
            try put("meta","lastAttempt",WireTime.string(now));return d
        }
    }
    func select(kind:String,bundle:String) throws {
        try transaction {
            var d=try dataset;let old=kind=="sleep" ? d.sources.sleep:d.sources.workout
            guard old==nil || old==bundle else{throw RelayError.source}
            if kind=="sleep"{d.sources.sleep=bundle}else{d.sources.workout=bundle}
            if old==nil{try remove("anchor",kind)};try put("meta","dataset",d)
        }
    }
    func ingest(_ page:HealthPage,kind:String) throws {
        try transaction {
            let d=try dataset;let deleted=Set(page.deletions);var changed=Set<String>()
            for sample in page.sleep where sample.source.bundleIdentifier==d.sources.sleep && !deleted.contains(sample.uuid) {
                if try get(SleepSample.self,"sleep",sample.uuid) != sample{
                    if let previous=try get(SleepSample.self,"sleep",sample.uuid){try put("affectedSleep",sample.uuid,previous)}
                    changed.insert(sample.uuid)
                };try put("sleep",sample.uuid,sample);try remove("unavailable",sample.uuid)
            }
            for sample in page.workouts where sample.source.bundleIdentifier==d.sources.workout && !deleted.contains(sample.uuid) {
                if try get(WorkoutSample.self,"workout",sample.uuid) != sample{changed.insert(sample.uuid)};try put("workout",sample.uuid,sample);try remove("unavailable",sample.uuid)
            }
            for uuid in deleted {
                let known = kind=="sleep" ? (try get(SleepSample.self,kind,uuid) != nil) : (try get(WorkoutSample.self,kind,uuid) != nil)
                let dependent=try list(StoredEntity.self,"entity").contains{$0.entity.payload.dependencies.contains(uuid)} || (try list(OutboxItem.self,"outbox").contains{$0.dependencies.contains(uuid)})
                if kind=="sleep",let previous=try get(SleepSample.self,"sleep",uuid){try put("affectedSleep",uuid,previous)}
                if known || dependent { changed.insert(uuid);try remove(kind,uuid);try remove("error",uuid);try remove("error","reconcile:"+uuid);try remove("unavailable",uuid);try put("deleted",uuid,true) }
            }
            if !changed.isEmpty {
                for var item in try list(OutboxItem.self,"outbox") where !item.dependencies.isDisjoint(with:changed) && item.state != "completed" {
                    item.state="superseded";try put("outbox",item.group.changeSetId,item)
                }
                for uuid in changed{try put("dirtyUUID",uuid,uuid)}
                try put("dirty",kind,true)
            }
            if !page.anchor.isEmpty { try put("anchor",kind,page.anchor);try put("reading",kind,!page.empty) }
        }
    }
    func pending() throws -> [OutboxItem] {
        try list(OutboxItem.self,"outbox").filter{["pending","retryable","partial","SOURCE_RECORD_UNAVAILABLE"].contains($0.state)}.sorted{($0.group.changes.first?.version ?? 0)<($1.group.changes.first?.version ?? 0)}
    }
    // Known remote possibilities include every attempted group, even without an acknowledgement.
    private struct ReconcileRejection {let reason:String;let dependencies:Set<String>}
    @discardableResult func reconcile(_ desired:[NormalizedEntity],kind:String,blockedUUIDs:Set<String>=[],
                                     relatedDependencies:(Set<String>)->Set<String> = {$0}) throws -> Set<String> {
        guard try get(Bool.self,"reading",kind) != true else{return []}
        return try transaction {
            // Discover rejected components before allowing their old-anchor deletes to survive.
            try execute("SAVEPOINT candidate_changes")
            let rejected=try reconcileChanges(desired,kind:kind,blockedUUIDs:blockedUUIDs,relatedDependencies:relatedDependencies)
            if rejected.isEmpty {try execute("RELEASE candidate_changes");return []}
            try execute("ROLLBACK TO candidate_changes");try execute("RELEASE candidate_changes")
            let blocked=relatedDependencies(rejected.values.reduce(into:Set<String>()){$0.formUnion($1.dependencies)})
            _ = try reconcileChanges(desired,kind:kind,blockedUUIDs:blockedUUIDs.union(blocked),relatedDependencies:relatedDependencies)
            for (_,rejection) in rejected{for uuid in rejection.dependencies{try put("error","reconcile:"+uuid,rejection.reason)}}
            return blocked
        }
    }
    private func reconcileChanges(_ desired:[NormalizedEntity],kind:String,blockedUUIDs:Set<String>,relatedDependencies:(Set<String>)->Set<String>) throws -> [String:ReconcileRejection] {
            var rejections:[String:ReconcileRejection]=[:]
            let stored=try list(StoredEntity.self,"entity").filter{$0.entity.kind==kind}
            var old=Dictionary(uniqueKeysWithValues:stored.map{($0.entity.entityId,$0.entity)})
            let remote=try list(NormalizedEntity.self,"remote").filter{$0.kind==kind}
            for remote in remote { if old[remote.entityId]==nil { old[remote.entityId]=remote } }
            let outbox=try list(OutboxItem.self,"outbox")
            for item in outbox where item.deliveryAttempted {
                for c in item.group.changes where c.kind==kind && c.action=="upsert" {
                    if let p=c.payload,old[c.entityId]==nil{old[c.entityId]=NormalizedEntity(entityId:c.entityId,kind:kind,payload:p)}
                }
            }
            let new=Dictionary(uniqueKeysWithValues:desired.map{($0.entityId,$0)})
            for uuid in Set(old.values.flatMap{$0.payload.dependencies}).union(desired.flatMap{$0.payload.dependencies}){try remove("error","reconcile:"+uuid)}
            var dependencyGraph:[String:Set<String>]=[:]
            for entity in stored.map(\.entity)+remote+desired {
                dependencyGraph[entity.entityId,default:[]].formUnion(entity.payload.dependencies)
            }
            // Prior immutable groups connect deleted IDs too, whose latest payload is now nil.
            let relatedGroups=outbox.filter{$0.group.changes.contains{$0.kind==kind}}
            for item in relatedGroups {
                for c in item.group.changes where c.kind==kind {
                    dependencyGraph[c.entityId,default:[]].formUnion(c.payload?.dependencies ?? [])
                }
            }
            for id in dependencyGraph.keys{dependencyGraph[id]=relatedDependencies(dependencyGraph[id] ?? [])}
            var touched=Set<String>()
            for (id,e) in old where new[id] != e {touched.insert(id)}
            for (id,e) in new where old[id] != e {touched.insert(id)}
            for item in outbox where item.state=="superseded" {
                for c in item.group.changes where c.kind==kind {touched.insert(c.entityId)}
            }
            // Partition by shared source dependencies so unrelated source records can proceed.
            while let seed=touched.first {
                var ids:Set<String>=[seed];var dependencies=Set<String>();var expanded=true
                while expanded {
                    expanded=false
                    for id in ids {dependencies.formUnion(dependencyGraph[id] ?? [])}
                    for (id,deps) in dependencyGraph where !ids.contains(id) {
                        if !deps.isDisjoint(with:dependencies){ids.insert(id);expanded=true}
                    }
                    for item in relatedGroups {
                        let priorIDs=Set(item.group.changes.filter{$0.kind==kind}.map(\.entityId))
                        if !priorIDs.isDisjoint(with:ids) && !priorIDs.isSubset(of:ids){ids.formUnion(priorIDs);expanded=true}
                    }
                }
                touched.subtract(ids)
                if !dependencies.isDisjoint(with:blockedUUIDs) {
                    // Neither a missing target nor a stale cached payload is a valid replacement.
                    for var item in relatedGroups where !["retired","superseded","completed"].contains(item.state) && item.group.changes.contains(where:{ids.contains($0.entityId)}) {
                        item.state="superseded";try put("outbox",item.group.changeSetId,item)
                    }
                    continue
                }
                var version=try get(Int64.self,"meta","nextVersion") ?? 1
                let changes=ids.sorted().compactMap { id -> Change? in
                    if let entity=new[id]{return Change(entityId:id,version:version,kind:kind,action:"upsert",payload:entity.payload)}
                    if old[id] != nil {return Change(entityId:id,version:version,kind:kind,action:"delete")};return nil
                }
                if changes.isEmpty{continue}
                let alreadyQueued=relatedGroups.first { item in
                    guard !["retired","completed"].contains(item.state),item.group.changes.count==changes.count else{return false}
                    return changes.allSatisfy { change in
                        item.group.changes.contains { queued in
                            queued.entityId==change.entityId && queued.kind==change.kind && queued.action==change.action && queued.payload==change.payload
                        }
                    }
                }
                if var queued=alreadyQueued {
                    if queued.state=="superseded"{queued.state="pending";queued.error=nil;try put("outbox",queued.group.changeSetId,queued)}
                    continue
                }
                guard version<Int64.max else{throw RelayError.conflict}
                let group=ChangeSet(changeSetId:newID(),changes:changes)
                let rejection:String?
                do {
                    try Contract.validate(group,dataset:dataset)
                    rejection=try WireCodec.encode(group).count>1_040_000 ? "RECORD_TOO_LARGE":nil
                }catch RelayError.invalidPayload{rejection="INVALID_PAYLOAD"}
                if let rejection {
                    rejections[seed]=ReconcileRejection(reason:rejection,dependencies:dependencies)
                    for uuid in dependencies{try put("error","reconcile:"+uuid,rejection)}
                    for var item in relatedGroups where !["retired","superseded","completed"].contains(item.state) && item.group.changes.contains(where:{ids.contains($0.entityId)}) {
                        item.state="superseded";try put("outbox",item.group.changeSetId,item)
                    }
                    continue
                }
                for var item in outbox where item.state != "completed" && item.group.changes.contains(where:{ids.contains($0.entityId)}) {
                    item.state="retired";try put("outbox",item.group.changeSetId,item)
                }
                try put("outbox",group.changeSetId,OutboxItem(group:group,deliveryAttempted:false,state:"pending"))
                for c in changes {
                    if let entity=new[c.entityId]{try put("entity",c.entityId,StoredEntity(entity:entity,version:version,confirmed:false))}
                    else{try remove("entity",c.entityId);try put("tombstone",c.entityId,version)}
                }
                version += 1;try put("meta","nextVersion",version)
            }
            try remove("dirty",kind)
            return rejections
    }
    func attempted(_ item:OutboxItem) throws {var item=item;item.deliveryAttempted=true;try put("outbox",item.group.changeSetId,item)}
    func outcome(_ item:OutboxItem,state:String,error:String?=nil) throws {
        try transaction {
            var updated=try get(OutboxItem.self,"outbox",item.group.changeSetId) ?? item
            updated.state=state;updated.error=error
            if state=="completed"{
                for c in item.group.changes {
                    if let p=c.payload { try put("remote",c.entityId,NormalizedEntity(entityId:c.entityId,kind:c.kind,payload:p)) } else { try remove("remote",c.entityId) }
                    if var e=try get(StoredEntity.self,"entity",c.entityId),e.version==c.version{e.confirmed=true;try put("entity",c.entityId,e)}
                }
                let completedIds=Set(item.group.changes.map(\.entityId))
                for prior in try list(OutboxItem.self,"outbox") where ["retired","superseded"].contains(prior.state) && Set(prior.group.changes.map(\.entityId)).isSubset(of:completedIds) { try remove("outbox",prior.group.changeSetId) }
                try remove("outbox",item.group.changeSetId)
            }else{try put("outbox",item.group.changeSetId,updated)}
        }
    }
    func markVisibility(known:Set<String>,visible:Set<String>) throws {
        try transaction {for id in known {if visible.contains(id){try remove("unavailable",id)}else if try get(Bool.self,"deleted",id) != true{try put("unavailable",id,id)}}}
    }
    func resetAnchors() throws {try transaction{for kind in ["sleep","workout"]{try remove("anchor",kind);try put("reading",kind,true)}}}
    @discardableResult func adoptRebuild(_ plan:RebuildPlan) throws -> Bool {
        try transaction {
            let current=try dataset
            guard Contract.validUUID(plan.planId),Contract.validUUID(plan.newDatasetId),
                  plan.oldDatasetId.map(Contract.validUUID) ?? true,
                  plan.oldDatasetId != plan.newDatasetId else{throw RelayError.recovery}
            _ = try WireTime.milliseconds(plan.historyStart)
            if let old=current.historyStart,old != plan.historyStart{throw RelayError.history}
            if current.datasetId==plan.newDatasetId {
                guard try get(RebuildPlan.self,"meta","plan")==plan,current.sources==plan.sources else{throw RelayError.recovery}
                return false
            }
            guard current.historyStart==nil || current.datasetId==plan.oldDatasetId else{throw RelayError.recovery}
            for bucket in ["anchor","sleep","workout","entity","remote","outbox","tombstone","deleted","dirty","dirtyUUID","affectedSleep","deferredSleep","reading","unavailable","error"] {
                let s=try statement("DELETE FROM state WHERE bucket=?",[bucket]);defer{sqlite3_finalize(s)};guard sqlite3_step(s)==SQLITE_DONE else{throw RelayError.storage}
            }
            try put("meta","dataset",Dataset(datasetId:plan.newDatasetId,historyStart:plan.historyStart,sources:plan.sources))
            try put("meta","nextVersion",Int64(1));try remove("meta","deferredSleep");try put("meta","plan",plan);try remove("meta","recovery")
            return true
        }
    }
    var cacheBytes:Int64 { ["","-wal","-shm"].reduce(0){$0+((try? FileManager.default.attributesOfItem(atPath:url.path+$1)[.size] as? Int64) ?? 0)} }
}
