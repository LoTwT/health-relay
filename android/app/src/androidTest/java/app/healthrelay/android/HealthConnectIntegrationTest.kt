package app.healthrelay.android

import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.metadata.DataOrigin
import androidx.health.connect.client.request.AggregateRequest
import androidx.health.connect.client.time.TimeRangeFilter
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith

/** Run only on an isolated synthetic-data emulator/device using -PhealthRelayAggregateTests=true. */
@RunWith(AndroidJUnit4::class)
class HealthConnectIntegrationTest {
    @Test fun C01_C04_C19_C30_C31_realWritesReadbackAggregationAndExactDelete()=runBlocking {
        Assume.assumeTrue("Real HC fixture test requires an isolated configuration",BuildConfig.HC_AGGREGATION_TESTS)
        val instrumentation=InstrumentationRegistry.getInstrumentation();val context=instrumentation.targetContext
        val scenario=androidx.test.core.app.ActivityScenario.launch(MainActivity::class.java)
        val writer=HealthConnectWriter(context);assertTrue("Health Connect available",writer.available())
        val permissions=HealthConnectWriter.requestedPermissions+"android.permission.health.READ_SLEEP"
        grantThroughSystemUi(permissions,scenario)
        val client=HealthConnectClient.getOrCreate(context)
        assertTrue("Test permissions granted",client.permissionController.getGrantedPermissions().containsAll(permissions))
        val fixtures=Wire.json.parseToJsonElement(instrumentation.context.assets.open("sleep-normalization.json").bufferedReader().use{it.readText()}).jsonArray
        for(name in listOf("C30_gap_20min","C30_gap_1ms","C30_awake_control","C31_awake_conflict")){
            val f=fixtures.first{it.jsonObject.getValue("name").jsonPrimitive.content==name}.jsonObject
            val dataset=Wire.json.decodeFromJsonElement<Dataset>(f.getValue("dataset"))
            val original=Wire.json.decodeFromJsonElement<List<Change>>(f.getValue("expected"))
            // Aggregation uses READ_SLEEP and its 30-day read window: shift only synthetic timestamps.
            val shift=java.time.Instant.now().minusSeconds(2*86400).toEpochMilli()-Wire.time(original.first().payload!!.start).toEpochMilli()
            val formatter=java.time.format.DateTimeFormatterBuilder().appendInstant(3).toFormatter()
            fun shifted(time:String)=formatter.format(Wire.time(time).plusMillis(shift))
            val changes=original.map { c ->
                val p=c.payload!!;val start=shifted(p.start)
                c.copy(entityId=c.entityId.substringBeforeLast('/')+"/"+Wire.time(start).toEpochMilli(),payload=p.copy(start=start,end=shifted(p.end),stages=p.stages!!.map{it.copy(start=shifted(it.start),end=shifted(it.end))}))
            }
            Wire.validate(ChangeSet(newId(),changes),dataset)
            try{
                repeat(3){writer.write(changes.map{it to "session"})}
                for(c in changes){val verified=writer.verify(c,"session");assertTrue("$name: ${writer.lastReadbackIssue}",verified)}
                val start=changes.minOf{Wire.time(it.payload!!.start)};val end=changes.maxOf{Wire.time(it.payload!!.end)}
                val aggregate=client.aggregate(AggregateRequest(setOf(SleepSessionRecord.SLEEP_DURATION_TOTAL),TimeRangeFilter.between(start,end),dataOriginFilter=setOf(DataOrigin(context.packageName))))
                assertEquals("$name aggregate",7200000L,aggregate[SleepSessionRecord.SLEEP_DURATION_TOTAL]?.toMillis())
            }finally{
                for(c in changes){val child=ChildRow(c.entityId+":session",c.entityId,"sleep",c.version,true);writer.delete(child);assertTrue(writer.absent(child))}
            }
        }
        scenario.close()
    }
    @Test fun C03_C04_C15_C29_realWorkoutAndOwnHistoricalReadback()=runBlocking {
        Assume.assumeTrue("Real HC fixture test requires an isolated configuration",BuildConfig.HC_AGGREGATION_TESTS)
        val instrumentation=InstrumentationRegistry.getInstrumentation();val context=instrumentation.targetContext
        val scenario=androidx.test.core.app.ActivityScenario.launch(MainActivity::class.java)
        val writer=HealthConnectWriter(context)
        for(permission in HealthConnectWriter.requestedPermissions){instrumentation.uiAutomation.executeShellCommand("pm grant ${context.packageName} $permission").use{descriptor->java.io.FileInputStream(descriptor.fileDescriptor).readBytes()}}
        val fixture=Wire.json.parseToJsonElement(instrumentation.context.assets.open("workout.json").bufferedReader().use{it.readText()}).jsonObject
        val group=Wire.json.decodeFromJsonElement<ChangeSet>(fixture.getValue("group"));val originalWorkout=group.changes[0].copy(version=1)
        val old=originalWorkout.payload!!
        val shift=java.time.Instant.now().minusSeconds(86400).toEpochMilli()-Wire.time(old.start).toEpochMilli()
        val formatter=java.time.format.DateTimeFormatterBuilder().appendInstant(3).toFormatter()
        fun shiftedWorkout(time:String)=formatter.format(Wire.time(time).plusMillis(shift))
        val c=originalWorkout.copy(payload=old.copy(start=shiftedWorkout(old.start),end=shiftedWorkout(old.end),pauses=old.pauses!!.map{it.copy(start=shiftedWorkout(it.start),end=shiftedWorkout(it.end))}))
        try{
            val children=ImportJournal.desiredChildren(c);writer.write(children.map{c to it})
            for(child in children){val verified=writer.verify(c,child);assertTrue("workout $child: ${writer.lastReadbackIssue}",verified)}
            val historical=originalWorkout.copy(version=2)
            writer.write(children.map{historical to it})
            for(child in children){val verified=writer.verify(historical,child);assertTrue("historical own workout $child: ${writer.lastReadbackIssue}",verified)}
        }
        finally{for(child in ImportJournal.desiredChildren(c)){val row=ChildRow(c.entityId+":"+child,c.entityId,ImportJournal.childType(c,child),c.version,true);writer.delete(row);assertTrue(writer.absent(row))};scenario.close()}
    }
    @Test fun C31_realConflictDisappearsWithoutResidualFragment()=runBlocking {
        Assume.assumeTrue("Isolated real HC fixture test",BuildConfig.HC_AGGREGATION_TESTS)
        val instrumentation=InstrumentationRegistry.getInstrumentation();val context=instrumentation.targetContext
        val scenario=androidx.test.core.app.ActivityScenario.launch(MainActivity::class.java)
        val db=androidx.room.Room.inMemoryDatabaseBuilder(context,RelayDatabase::class.java).build()
        val writer=HealthConnectWriter(context);val journal=ImportJournal(db,writer);journal.allowed=true
        grantThroughSystemUi(HealthConnectWriter.requestedPermissions+"android.permission.health.READ_SLEEP",scenario)
        val fixtures=Wire.json.parseToJsonElement(instrumentation.context.assets.open("sleep-normalization.json").bufferedReader().use{it.readText()}).jsonArray
        val fixture=fixtures.first{it.jsonObject["name"]!!.jsonPrimitive.content=="C31_awake_conflict"}.jsonObject
        val dataset=Wire.json.decodeFromJsonElement<Dataset>(fixture.getValue("dataset"))
        val original=Wire.json.decodeFromJsonElement<List<Change>>(fixture.getValue("expected"))
        val shift=java.time.Instant.now().minusSeconds(2*86400).toEpochMilli()-Wire.time(original[0].payload!!.start).toEpochMilli()
        val formatter=java.time.format.DateTimeFormatterBuilder().appendInstant(3).toFormatter()
        fun moved(time:String)=formatter.format(Wire.time(time).plusMillis(shift))
        val fragments=original.map{c->val p=c.payload!!;val start=moved(p.start);c.copy(entityId=c.entityId.substringBeforeLast('/')+"/"+Wire.time(start).toEpochMilli(),payload=p.copy(start=start,end=moved(p.end),stages=p.stages!!.map{it.copy(start=moved(it.start),end=moved(it.end))}))}
        try{
            journal.bind(dataset);journal.apply(ChangeSet(newId(),fragments),dataset)
            val p=fragments[0].payload!!;val end=fragments[1].payload!!.end
            val merged=fragments[0].copy(version=2,payload=p.copy(end=end,warnings=emptyList(),stages=listOf(Stage(p.start,end,"light"))))
            val removed=fragments[1].copy(version=2,action="delete",payload=null)
            val group=ChangeSet(newId(),listOf(removed,merged));repeat(3){journal.apply(group,dataset)}
            assertTrue(writer.verify(merged,"session"))
            assertTrue(writer.absent(ChildRow(removed.entityId+":session",removed.entityId,"sleep",2,true)))
            val ids=writer.ownRecords("sleep").filter{it.clientId.startsWith("hr1/${dataset.datasetId}/")}.map{it.clientId}
            assertEquals(listOf(merged.entityId+":session"),ids)
            val client=HealthConnectClient.getOrCreate(context)
            val result=client.aggregate(AggregateRequest(setOf(SleepSessionRecord.SLEEP_DURATION_TOTAL),TimeRangeFilter.between(Wire.time(p.start),Wire.time(end)),dataOriginFilter=setOf(DataOrigin(context.packageName))))
            assertEquals(8400000L,result[SleepSessionRecord.SLEEP_DURATION_TOTAL]?.toMillis())
        }finally{
            for(c in fragments)writer.delete(ChildRow(c.entityId+":session",c.entityId,"sleep",2,true))
            db.close();scenario.close()
        }
    }
    private suspend fun grantThroughSystemUi(permissions:Set<String>,scenario:androidx.test.core.app.ActivityScenario<MainActivity>){
        val instrumentation=InstrumentationRegistry.getInstrumentation();val context=instrumentation.targetContext
        val client=HealthConnectClient.getOrCreate(context)
        if(client.permissionController.getGrantedPermissions().containsAll(permissions))return
        scenario.onActivity{activity->activity.requestPermissions(permissions.toTypedArray(),901)}
        val deadline=System.currentTimeMillis()+20000;var selectedAll=false
        fun find(node:android.view.accessibility.AccessibilityNodeInfo?,text:String):android.view.accessibility.AccessibilityNodeInfo?{
            if(node==null)return null
            if(node.text?.toString()?.equals(text,ignoreCase=true)==true)return node
            for(i in 0 until node.childCount){val found=find(node.getChild(i),text);if(found!=null)return found};return null
        }
        while(System.currentTimeMillis()<deadline){
            if(client.permissionController.getGrantedPermissions().containsAll(permissions))return
            val root=instrumentation.uiAutomation.rootInActiveWindow
            val labels=if(selectedAll)listOf("Allow","Get started","Continue")else listOf("Get started","Allow all","Continue")
            for(label in labels){var node=find(root,label);if(node!=null){while(node!=null&&!node.isClickable)node=node.parent;node?.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK);if(label=="Allow all")selectedAll=true;break}}
            kotlinx.coroutines.delay(200)
        }
        error("Health Connect permission UI did not grant synthetic-test permissions")
    }

}
