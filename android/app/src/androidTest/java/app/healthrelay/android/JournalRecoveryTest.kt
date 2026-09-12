package app.healthrelay.android

import androidx.room.Room
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class JournalRecoveryTest {
    private lateinit var db:RelayDatabase
    private lateinit var fake:MemoryHealth
    private lateinit var journal:ImportJournal
    private lateinit var dataset:Dataset
    private lateinit var group:ChangeSet
    @Before fun setup()=runBlocking {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        db=Room.inMemoryDatabaseBuilder(context,RelayDatabase::class.java).build();fake=MemoryHealth();journal=ImportJournal(db,fake);journal.allowed=true
        val text=InstrumentationRegistry.getInstrumentation().context.assets.open("workout.json").bufferedReader().use{it.readText()}
        val fixture=Wire.json.parseToJsonElement(text).jsonObject
        dataset=Wire.json.decodeFromJsonElement(fixture.getValue("dataset"));group=Wire.json.decodeFromJsonElement<ChangeSet>(fixture.getValue("group")).let{it.copy(changes=it.changes.map{c->c.copy(version=1)})}
        journal.bind(dataset)
    }
    @After fun close(){db.close()}
    @Test fun C01_C02_replayThreeTimesAndLostAcknowledgement()=runBlocking {
        repeat(3){assertEquals("applied",journal.apply(group,dataset).entities[0].status)}
        assertEquals(3,fake.records.size);assertEquals(1,fake.insertCalls)
        assertNull(db.dao().journal(group.changeSetId)!!.payload)
    }
    @Test fun C20_writeBeforeJournalCompletionCrashRecovers()=runBlocking {
        fake.crashAfterWrite=true
        try{journal.apply(group,dataset);fail()}catch(_:IllegalStateException){}
        assertEquals(3,fake.records.size);assertNotNull(db.dao().journal(group.changeSetId)!!.payload)
        fake.crashAfterWrite=false
        val restarted=ImportJournal(db,fake);restarted.allowed=true;restarted.recover()
        assertEquals(3,fake.records.size);assertEquals("complete",db.dao().journal(group.changeSetId)!!.state)
    }
    @Test fun C19_partialPermissionOnlyRetriesMissingChildren()=runBlocking {
        fake.granted=setOf("exercise","sleep")
        assertEquals("partial",journal.apply(group,dataset).entities[0].status);assertEquals(1,fake.records.size)
        fake.granted=allTypes
        assertEquals("applied",journal.apply(group,dataset).entities[0].status)
        assertEquals(1,fake.written.count{it.endsWith(":session")});assertEquals(3,fake.records.size)
    }
    @Test fun C03_unavailableRetainsPreviouslyWrittenStatistic()=runBlocking {
        journal.apply(group,dataset)
        val newer=group.copy(changeSetId=newId(),changes=group.changes.map{it.copy(version=2,payload=it.payload!!.copy(distance=Statistic("unavailable")))})
        val result=journal.apply(newer,dataset)
        assertEquals("retained",result.entities[0].children["distance"])
        assertEquals(3,fake.records.size)
        assertEquals(1L,fake.records.getValue(group.changes[0].entityId+":distance").version)
    }
    @Test fun C04_C22_C33_exactDeleteAndTombstonePreventResurrection()=runBlocking {
        journal.apply(group,dataset)
        val deletion=group.copy(changeSetId=newId(),changes=group.changes.map{it.copy(version=3,action="delete",payload=null)})
        journal.apply(deletion,dataset);assertTrue(fake.records.isEmpty());assertEquals(3,fake.deleted.size)
        val older=group.copy(changeSetId=newId(),changes=group.changes.map{it.copy(version=2)})
        assertEquals("superseded",journal.apply(older,dataset).entities[0].status);assertTrue(fake.records.isEmpty())
        val unknown=deletion.copy(changeSetId=newId(),changes=deletion.changes.map{it.copy(entityId="hr1/${dataset.datasetId}/workout/${newId()}",version=4)})
        journal.apply(unknown,dataset);assertEquals(3,fake.deleted.size)
    }
    @Test fun C22_conflictingGroupCannotChangeContent()=runBlocking {
        journal.apply(group,dataset)
        val conflict=group.copy(changes=group.changes.map{it.copy(version=2)})
        try{journal.apply(conflict,dataset);fail()}catch(e:RelayFailure){assertEquals("VERSION_CONFLICT",e.code)}
    }
    @Test fun C18_C21_mandatoryPermissionFailureDoesNotBlockIndependentGroup()=runBlocking {
        fake.granted=setOf("sleep")
        try{journal.apply(group,dataset);fail()}catch(e:RelayFailure){assertEquals("PERMISSION_REQUIRED",e.code)}
        assertTrue(fake.records.isEmpty())
        fake.granted=allTypes;journal.apply(group,dataset);assertEquals(3,fake.records.size)
    }
    @Test fun C27_C29_C35_rebuildPlanAndHistoryGuard()=runBlocking {
        journal.apply(group,dataset)
        val plan=RebuildPlan(newId(),dataset.datasetId,newId(),dataset.historyStart,dataset.sources)
        journal.prepare(plan);journal.prepare(plan);assertEquals(3,fake.records.size)
        try{journal.prepare(plan.copy(historyStart="2020-01-01T00:00:00.000Z"));fail()}catch(e:RelayFailure){assertEquals("VERSION_CONFLICT",e.code)}
        journal.clearConfirmed();assertEquals("cleared",journal.state());assertTrue(fake.records.isEmpty())
        try{journal.apply(group,dataset);fail()}catch(e:RelayFailure){assertEquals("RECOVERY_REQUIRED",e.code)}
        journal.bindRebuilt(Dataset(plan.newDatasetId,plan.historyStart,plan.sources));assertEquals("ready",journal.state());assertEquals(dataset.historyStart,journal.dataset()!!.historyStart)
        try{journal.bind(dataset);fail()}catch(_:RelayFailure){}
    }
    @Test fun C26_orphanedOwnRecordRequiresRecoveryBeforeWriting()=runBlocking {
        db.dao().removeConfig("checked:exercise")
        val orphan=ChildRow("hr1/${newId()}/workout/${newId()}:session","orphan","exercise",1,true);fake.records[orphan.clientId]=orphan
        try{journal.apply(group,dataset);fail()}catch(e:RelayFailure){assertEquals("RECOVERY_REQUIRED",e.code)}
        assertEquals(1,fake.records.size)
    }
    @Test fun C20_transientIpcRetriesWithStableIdentities()=runBlocking {
        fake.transientWriteFailures=1
        assertEquals("applied",journal.apply(group,dataset).entities[0].status)
        assertEquals(2,fake.insertCalls);assertEquals(3,fake.records.size)
    }
    @Test fun C35_partialClearResumesSamePlan()=runBlocking {
        journal.apply(group,dataset)
        val plan=RebuildPlan(newId(),dataset.datasetId,newId(),dataset.historyStart,dataset.sources)
        journal.prepare(plan);fake.crashAfterDelete=true
        try{journal.clearConfirmed();fail()}catch(_:IllegalStateException){}
        assertEquals("clearing",journal.state());assertEquals(plan,journal.recoveryInfo()!!.rebuildPlan)
        fake.crashAfterDelete=false
        val restarted=ImportJournal(db,fake);restarted.clearConfirmed()
        assertTrue(fake.records.isEmpty());assertEquals("cleared",restarted.state())
        restarted.clearConfirmed();assertEquals(plan,restarted.recoveryInfo()!!.rebuildPlan)
    }
    @Test fun C20_readbackMismatchMustRetainPayload()=runBlocking {
        fake.forceReadbackMismatch=true
        try{journal.apply(group,dataset);fail("Readback mismatch must not return applied")}catch(e:RelayFailure){assertEquals("READBACK_MISMATCH",e.code)}
        assertNotNull("Unconfirmed payload must remain recoverable",db.dao().journal(group.changeSetId)!!.payload)
        assertNotEquals("complete",db.dao().journal(group.changeSetId)!!.state)
        fake.forceReadbackMismatch=false
        val restarted=ImportJournal(db,fake);restarted.allowed=true;restarted.recover()
        assertEquals("complete",db.dao().journal(group.changeSetId)!!.state)
        assertNull(db.dao().journal(group.changeSetId)!!.payload)
        assertEquals(3,fake.records.size)
    }
    @Test fun C29_newPlanCannotChangeTrustedHistory()=runBlocking {
        journal.apply(group,dataset)
        val wrong=RebuildPlan(newId(),dataset.datasetId,newId(),"2020-01-01T00:00:00.000Z",dataset.sources)
        try{journal.prepare(wrong);fail("A new planId must not bypass the trusted history guard")}catch(e:RelayFailure){assertEquals("HISTORY_RANGE_MISMATCH",e.code)}
        assertNull(journal.configuration("plan"));assertEquals(3,fake.records.size)
        journal.prepare(wrong.copy(historyStart=dataset.historyStart))
        assertNotNull(journal.configuration("plan"));assertTrue(fake.deleted.isEmpty())
    }
    class MemoryHealth:HealthGateway {
        var forceReadbackMismatch=false
        val records=linkedMapOf<String,ChildRow>();val written=mutableListOf<String>();val deleted=mutableListOf<String>();var insertCalls=0;var crashAfterWrite=false;var crashAfterDelete=false;var transientWriteFailures=0;var granted=allTypes
        override suspend fun permissions()=granted
        override fun validate(change:Change){}
        override suspend fun write(changes:List<Pair<Change,String>>){insertCalls++;if(transientWriteFailures>0){transientWriteFailures--;throw java.io.IOException("synthetic IPC interruption")};for((c,child)in changes){val id=c.entityId+":"+child;written+=id;records[id]=ChildRow(id,c.entityId,ImportJournal.childType(c,child),c.version,true)};if(crashAfterWrite)error("synthetic crash")}
        override suspend fun verify(change:Change,child:String)= !forceReadbackMismatch && records[change.entityId+":"+child]?.version==change.version
        override suspend fun delete(child:ChildRow){deleted+=child.clientId;records.remove(child.clientId);if(crashAfterDelete)error("synthetic clear crash")}
        override suspend fun absent(child:ChildRow)=child.clientId !in records
        override suspend fun ownRecords(type:String)=records.values.filter{it.type==type}
    }
    companion object{val allTypes=setOf("sleep","exercise","distance","active-energy")}
}
