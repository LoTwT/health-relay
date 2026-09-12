package app.healthrelay.android

import androidx.room.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.encodeToString

@Entity(tableName="configuration") data class ConfigurationRow(@PrimaryKey val key:String,val value:String)
@Entity(tableName="entities") data class EntityRow(@PrimaryKey val id:String,val kind:String,val version:Long,val digest:String,val deleted:Boolean)
@Entity(tableName="children") data class ChildRow(@PrimaryKey val clientId:String,val entityId:String,val type:String,val version:Long,val complete:Boolean)
@Entity(tableName="journals") data class JournalRow(@PrimaryKey val id:String,val digest:String,val payload:String?,val result:String?,val state:String)
@Dao interface RelayDao {
    @Query("SELECT * FROM configuration WHERE `key`=:key") suspend fun config(key:String):ConfigurationRow?
    @Insert(onConflict=OnConflictStrategy.REPLACE) suspend fun config(row:ConfigurationRow)
    @Query("DELETE FROM configuration WHERE `key`=:key") suspend fun removeConfig(key:String)
    @Query("SELECT * FROM entities WHERE id=:id") suspend fun entity(id:String):EntityRow?
    @Query("SELECT * FROM entities") suspend fun entities():List<EntityRow>
    @Insert(onConflict=OnConflictStrategy.REPLACE) suspend fun entity(row:EntityRow)
    @Query("SELECT * FROM children WHERE entityId=:entityId") suspend fun children(entityId:String):List<ChildRow>
    @Query("SELECT * FROM children") suspend fun children():List<ChildRow>
    @Insert(onConflict=OnConflictStrategy.REPLACE) suspend fun child(row:ChildRow)
    @Query("DELETE FROM children WHERE clientId=:id") suspend fun removeChild(id:String)
    @Query("SELECT * FROM journals WHERE id=:id") suspend fun journal(id:String):JournalRow?
    @Query("SELECT * FROM journals WHERE payload IS NOT NULL ORDER BY rowid") suspend fun pending():List<JournalRow>
    @Insert(onConflict=OnConflictStrategy.REPLACE) suspend fun journal(row:JournalRow)
    @Query("DELETE FROM entities") suspend fun clearEntities()
    @Query("DELETE FROM children") suspend fun clearChildren()
    @Query("DELETE FROM journals") suspend fun clearJournals()
}
@Database(entities=[ConfigurationRow::class,EntityRow::class,ChildRow::class,JournalRow::class],version=1,exportSchema=true)
abstract class RelayDatabase:RoomDatabase(){ abstract fun dao():RelayDao }

interface HealthGateway {
    suspend fun permissions():Set<String>
    fun validate(change:Change)
    suspend fun write(changes:List<Pair<Change,String>>)
    suspend fun verify(change:Change,child:String):Boolean
    suspend fun delete(child:ChildRow)
    suspend fun absent(child:ChildRow):Boolean
    suspend fun ownRecords(type:String):List<ChildRow>
}

class ImportJournal(private val database:RelayDatabase,private val health:HealthGateway) {
    private val dao=database.dao()
    val mutex=Mutex()
    @Volatile var allowed=false
    private fun checkActive(){requireRelay(allowed,"RECEIVER_STOPPED")}
    private suspend fun <T> retryHealth(requireReceiving:Boolean=true,operation:suspend ()->T):T {
        for(attempt in 0..3){
            if(requireReceiving)checkActive()
            try{return operation()}catch(error:Exception){
                if(error !is android.os.RemoteException && error !is java.io.IOException)throw error
                if(attempt==3)throw RelayFailure("IMPORT_RETRYABLE")
                kotlinx.coroutines.delay(longArrayOf(1000,2000,4000)[attempt])
            }
        }
        throw RelayFailure("IMPORT_RETRYABLE")
    }
    suspend fun removePair()=dao.removeConfig("pair")
    suspend fun configuration(key:String)=dao.config(key)?.value
    suspend fun save(key:String,value:String)=dao.config(ConfigurationRow(key,value))
    suspend fun state()=configuration("state")?:"ready"
    suspend fun dataset():Dataset?=configuration("dataset")?.let{Wire.json.decodeFromString<Dataset>(it)}
    suspend fun bind(value:Dataset) = mutex.withLock {
        val old=dataset()
        requireRelay(configuration("retired:${value.datasetId}")==null,"RECOVERY_REQUIRED")
        if(old!=null){
            requireRelay(old.datasetId==value.datasetId,"RECOVERY_REQUIRED")
            requireRelay(old.historyStart==value.historyStart,"HISTORY_RANGE_MISMATCH")
            requireRelay((old.sources.sleep==null || old.sources.sleep==value.sources.sleep)&&(old.sources.workout==null || old.sources.workout==value.sources.workout),"SOURCE_CONFIG_MISMATCH")
        }
        requireRelay(state()=="ready","RECOVERY_REQUIRED")
        checkOrphans(health.permissions())
        save("dataset",Wire.json.encodeToString(value))
    }
    private suspend fun checkOrphans(types:Set<String>) {
        for(type in types){
            if(configuration("checked:$type")=="true")continue
            checkActive()
            val known=dao.children().map{it.clientId}.toSet()
            val orphans=health.ownRecords(type).filter{it.clientId !in known}
            if(orphans.isNotEmpty()){
                val ids=orphans.map{it.clientId.split('/').getOrNull(1)}.filterNotNull().distinct()
                save("orphanDatasets",Wire.json.encodeToString(ids));save("state","RECOVERY_REQUIRED");throw RelayFailure("RECOVERY_REQUIRED")
            }
            save("checked:$type","true")
        }
    }
    suspend fun apply(group:ChangeSet,dataset:Dataset):GroupResult = mutex.withLock { applyLocked(group,dataset) }
    private suspend fun applyLocked(group:ChangeSet,dataset:Dataset):GroupResult {
        checkActive();requireRelay(state()=="ready","RECOVERY_REQUIRED");Wire.validate(group,dataset)
        val digest=Wire.digest(group);val existing=dao.journal(group.changeSetId)
        requireRelay(existing==null || existing.digest==digest,"VERSION_CONFLICT")
        if(existing?.state=="superseded")return stale(group)
        val prior=group.changes.map{it to dao.entity(it.entityId)}
        if(prior.any{(c,e)->e!=null&&e.version>c.version}){
            val result=stale(group);dao.journal(JournalRow(group.changeSetId,digest,null,Wire.json.encodeToString(result),"superseded"));return result
        }
        if(existing?.state=="complete")return Wire.json.decodeFromString(existing.result!!)
        for((c,e) in prior){requireRelay(e==null || e.version!=c.version || e.digest==sha256(Wire.canonical(Wire.json.encodeToJsonElement(Change.serializer(),c))),"VERSION_CONFLICT")}
        if(existing==null)dao.journal(JournalRow(group.changeSetId,digest,Wire.json.encodeToString(group),null,"received"))
        // Construct every record before any external mutation. A bad mandatory record stops its group.
        group.changes.filter{it.action=="upsert"}.forEach(health::validate)
        val permissions=health.permissions()
        val deleteChildren=group.changes.filter{it.action=="delete"}.flatMap{dao.children(it.entityId)}
        val mandatory=group.changes.filter{it.action=="upsert"}.map{if(it.kind=="sleep")"sleep" else "exercise"}.toSet()+deleteChildren.map{it.type}
        requireRelay(permissions.containsAll(mandatory),"PERMISSION_REQUIRED")
        checkOrphans(permissions)
        if(existing==null||existing.state=="received"){
            database.withTransaction {
                // Reserve identities and all potentially written children before crossing the HC boundary.
                dao.journal(JournalRow(group.changeSetId,digest,Wire.json.encodeToString(group),null,"pending"))
                for(c in group.changes){
                    dao.entity(EntityRow(c.entityId,c.kind,c.version,sha256(Wire.canonical(Wire.json.encodeToJsonElement(Change.serializer(),c))),c.action=="delete"))
                    if(c.action=="upsert") for(child in desiredChildren(c)) {
                        val old=dao.children(c.entityId).firstOrNull{it.clientId==c.entityId+":"+child}
                        if(old?.version!=c.version)dao.child(ChildRow(c.entityId+":"+child,c.entityId,childType(c,child),c.version,false))
                    }
                }
            }
        }
        // A lost acknowledgement repeats exact deletes/upserts; every boundary is journaled.
        for(child in deleteChildren){checkActive();retryHealth{health.delete(child)};checkActive();requireRelay(retryHealth{health.absent(child)},"READBACK_MISMATCH");dao.removeChild(child.clientId)}
        val writes=mutableListOf<Pair<Change,String>>()
        for(c in group.changes.filter{it.action=="upsert"})for(child in desiredChildren(c)){
            val row=dao.children(c.entityId).first{it.clientId==c.entityId+":"+child}
            if(childType(c,child) in permissions && !row.complete)writes+=c to child
        }
        if(writes.isNotEmpty()){
            checkActive();retryHealth{health.write(writes)}
            for((c,child) in writes){checkActive();requireRelay(retryHealth{health.verify(c,child)},"READBACK_MISMATCH");dao.child(ChildRow(c.entityId+":"+child,c.entityId,childType(c,child),c.version,true))}
        }
        val results=group.changes.map{c ->
            if(c.action=="delete")EntityResult(c.entityId,c.version,"applied",mapOf("session" to "applied"))
            else {
                val rows=dao.children(c.entityId)
                val children=linkedMapOf<String,String>()
                for(child in desiredChildren(c))children[child]=if(rows.any{it.clientId==c.entityId+":"+child&&it.version==c.version&&it.complete})"applied" else "PERMISSION_REQUIRED"
                if(c.kind=="workout"){
                    if(c.payload!!.distance!!.state=="unavailable")children["distance"]=if(rows.any{it.clientId==c.entityId+":distance"})"retained" else "unavailable"
                    if(c.payload.activeEnergy!!.state=="unavailable")children["active-energy"]=if(rows.any{it.clientId==c.entityId+":active-energy"})"retained" else "unavailable"
                }
                EntityResult(c.entityId,c.version,if(children.values.any{it=="PERMISSION_REQUIRED"})"partial" else "applied",children)
            }
        }
        val result=GroupResult(group.changeSetId,results);val complete=results.none{it.status=="partial"}
        save("lastResult",Wire.json.encodeToString(result))
        dao.journal(JournalRow(group.changeSetId,digest,if(complete)null else Wire.json.encodeToString(group),Wire.json.encodeToString(result),if(complete)"complete" else "partial"))
        return result
    }
    suspend fun recover()=mutex.withLock {
        val dataset=dataset()?:return@withLock
        if(state()!="ready")return@withLock
        for(row in dao.pending()){
            checkActive()
            try{applyLocked(Wire.json.decodeFromString(row.payload!!),dataset)}catch(e:RelayFailure){if(e.code=="RECEIVER_STOPPED")throw e}catch(_:SecurityException){/* Preserve journal until the next permission grant. */}
        }
    }
    private fun stale(group:ChangeSet)=GroupResult(group.changeSetId,group.changes.map{EntityResult(it.entityId,it.version,"superseded",emptyMap())})
    suspend fun inspectRecovery() {
        if(state()!="RECOVERY_REQUIRED")return
        val ids=mutableSetOf<String>()
        for(type in health.permissions())for(child in health.ownRecords(type)){
            child.clientId.split('/').getOrNull(1)?.let{ids+=it}
        }
        if(ids.isNotEmpty())save("orphanDatasets",Wire.json.encodeToString(ids.sorted()))
    }
    suspend fun recoveryInfo():RecoveryInfo? {
        val d=dataset();val plan=configuration("plan")?.let{Wire.json.decodeFromString<RebuildPlan>(it)}
        val orphans=configuration("orphanDatasets")?.let{Wire.json.decodeFromString<List<String>>(it)}?:emptyList()
        if(d==null&&plan==null&&orphans.isEmpty())return null
        return RecoveryInfo(d?.datasetId?:orphans.singleOrNull(),d?.historyStart,d?.sources,plan,configuration("rebuildState"))
    }
    suspend fun prepare(plan:RebuildPlan)=mutex.withLock {
        Wire.uuid(plan.planId);Wire.uuid(plan.newDatasetId);Wire.time(plan.historyStart)
        val old=dataset();val previous=configuration("plan")?.let{Wire.json.decodeFromString<RebuildPlan>(it)}
        if(previous?.planId==plan.planId){requireRelay(previous==plan,"VERSION_CONFLICT");return@withLock}
        requireRelay(state() !in setOf("clearing","cleared"),"RECOVERY_REQUIRED")
        requireRelay(plan.newDatasetId!=plan.oldDatasetId && configuration("retired:${plan.newDatasetId}")==null,"RECOVERY_REQUIRED")
        if(old!=null){requireRelay(plan.oldDatasetId==old.datasetId,"RECOVERY_REQUIRED");requireRelay(plan.historyStart==old.historyStart,"HISTORY_RANGE_MISMATCH")}
        val orphans=configuration("orphanDatasets")?.let{Wire.json.decodeFromString<List<String>>(it)}?:emptyList()
        if(plan.oldDatasetId==null)requireRelay(dao.entities().isEmpty()&&orphans.isEmpty(),"RECOVERY_REQUIRED")
        if(old==null&&orphans.isNotEmpty())requireRelay(orphans.size==1&&plan.oldDatasetId==orphans.single(),"RECOVERY_REQUIRED")
        database.withTransaction{save("plan",Wire.json.encodeToString(plan));save("rebuildState","prepared")}
    }
    suspend fun cancelPrepared()=mutex.withLock {
        requireRelay(configuration("rebuildState")=="prepared","RECOVERY_REQUIRED")
        database.withTransaction{dao.removeConfig("plan");dao.removeConfig("rebuildState")}
    }
    suspend fun clearConfirmed()=mutex.withLock {
        val plan=configuration("plan")?.let{Wire.json.decodeFromString<RebuildPlan>(it)}?:throw RelayFailure("RECOVERY_REQUIRED")
        requireRelay(health.permissions().containsAll(setOf("sleep","exercise","distance","active-energy")),"PERMISSION_REQUIRED")
        database.withTransaction{save("state","clearing");save("rebuildState","clearing")}
        // Enumerate this DataOrigin only, then delete each exact hr1 client ID. No date-range deletion.
        for(type in listOf("sleep","exercise","distance","active-energy")){
            val known=dao.children().filter{it.type==type}
            val all=(known+health.ownRecords(type)).associateBy{it.clientId}.values
            for(child in all){retryHealth(false){health.delete(child)};requireRelay(retryHealth(false){health.absent(child)},"READBACK_MISMATCH")}
        }
        database.withTransaction {
            plan.oldDatasetId?.let{save("retired:$it","true")};dao.removeConfig("orphanDatasets");save("state","cleared");save("rebuildState","cleared")
            dao.removeConfig("pair");dao.clearEntities();dao.clearChildren();dao.clearJournals()
        }
    }
    suspend fun bindRebuilt(value:Dataset)=mutex.withLock {
        val plan=configuration("plan")?.let{Wire.json.decodeFromString<RebuildPlan>(it)}?:throw RelayFailure("RECOVERY_REQUIRED")
        requireRelay(state()=="cleared"&&value.datasetId==plan.newDatasetId&&value.historyStart==plan.historyStart&&value.sources==plan.sources,"RECOVERY_REQUIRED")
        database.withTransaction{save("dataset",Wire.json.encodeToString(value));save("state","ready")}
    }
    suspend fun saveGeneration(id:String,results:List<GroupResult>) {
        val key="generation:$id"
        val previous=configuration(key)?.let{Wire.json.decodeFromString<List<GroupResult>>(it)}?:emptyList()
        val index=configuration("generationIndex")?.let{Wire.json.decodeFromString<List<String>>(it)}?:emptyList()
        val updated=(index.filter{it!=id}+id)
        database.withTransaction {
            save(key,Wire.json.encodeToString((previous+results).associateBy{it.changeSetId}.values.toList()))
            for(old in updated.dropLast(200))dao.removeConfig("generation:$old")
            save("generationIndex",Wire.json.encodeToString(updated.takeLast(200)))
        }
    }
    suspend fun counts()=dao.children().groupingBy{it.type}.eachCount()
    companion object {
        fun desiredChildren(c:Change):List<String> = if(c.action=="delete")emptyList() else buildList {
            add("session");if(c.kind=="workout") {if(c.payload!!.distance!!.state=="value")add("distance");if(c.payload.activeEnergy!!.state=="value")add("active-energy")}
        }
        fun childType(c:Change,child:String)=if(child=="session")if(c.kind=="sleep")"sleep" else "exercise" else child
    }
}
