package app.healthrelay.android

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.*

class ContractTest {
    private fun fixture(name:String)=javaClass.classLoader!!.getResourceAsStream("$name.json")!!.bufferedReader().use{Wire.json.parseToJsonElement(it.readText())}
    @Test fun sharedWorkoutPreservesInt64AndNull(){
        val f=fixture("workout").jsonObject;val d=Wire.json.decodeFromJsonElement<Dataset>(f.getValue("dataset"));val group=Wire.json.decodeFromJsonElement<ChangeSet>(f.getValue("group"))
        Wire.validate(group,d);assertEquals(9223372036854775806L,group.changes[0].version)
        val encoded=Wire.json.encodeToJsonElement(ChangeSet.serializer(),group);assertEquals(group,Wire.json.decodeFromJsonElement<ChangeSet>(encoded))
        assertTrue(encoded.jsonObject.getValue("changes").jsonArray[0].jsonObject.getValue("payload").jsonObject.getValue("source").jsonObject.getValue("model") is JsonNull)
        val unknown=group.copy(changes=group.changes.map{it.copy(payload=it.payload!!.copy(indoor=null))})
        val nullable=Wire.json.encodeToJsonElement(ChangeSet.serializer(),unknown).jsonObject["changes"]!!.jsonArray[0].jsonObject["payload"]!!.jsonObject
        assertEquals(JsonNull,nullable["indoor"])
        assertEquals(325.5,group.changes[0].payload!!.activeEnergy!!.kcal!!,0.0)
    }
    @Test fun sharedSleepContractsAndDurations(){
        fixture("sleep-normalization").jsonArray.forEach{raw->
            val f=raw.jsonObject;val d=Wire.json.decodeFromJsonElement<Dataset>(f.getValue("dataset"));val changes=Wire.json.decodeFromJsonElement<List<Change>>(f.getValue("expected"))
            if(changes.isNotEmpty())Wire.validate(ChangeSet("22222222-2222-4222-8222-222222222222",changes),d)
            val name=f.getValue("name").jsonPrimitive.content
            if(name.startsWith("C30")||name.startsWith("C31")){
                val sleep=changes.sumOf{c->c.payload!!.stages!!.filter{it.type!="awake"}.sumOf{Wire.time(it.end).toEpochMilli()-Wire.time(it.start).toEpochMilli()}}
                assertEquals(name,7200000L,sleep)
            }
        }
    }
    @Test fun allMalformedSharedContractsAreRejected(){
        val f=fixture("invalid-contract").jsonObject;val d=Wire.json.decodeFromJsonElement<Dataset>(f.getValue("dataset"))
        f.getValue("cases").jsonArray.forEach{raw->val c=raw.jsonObject
            try{Wire.validate(Wire.json.decodeFromJsonElement(c.getValue("group")),d);fail(c.getValue("name").jsonPrimitive.content)}catch(_:Exception){}
        }
    }
    @Test fun frameParserAccumulatesPartialReadsAndRejectsBeforeAllocation(){
        val message=buildJsonObject{put("test",1)};val out=ByteArrayOutputStream();Wire.write(DataOutputStream(out),message)
        val bytes=out.toByteArray();val input=object:ByteArrayInputStream(bytes){override fun read(b:ByteArray,off:Int,len:Int)=super.read(b,off,minOf(len,1))}
        assertEquals(message,Wire.read(DataInputStream(input)))
        for(n in listOf(0,1048577,-1))try{Wire.length(n);fail("$n")}catch(_:RelayFailure){}
        assertEquals(1048576,Wire.length(1048576))
    }
    @Test fun wrongTokenDoesNotCompareEqual(){assertFalse(LanReceiver.constantEqual("token-a","token-b"));assertTrue(LanReceiver.constantEqual("token-a","token-a"))}
    @Test fun conflictingUnknownSleepCannotPassValidator(){
        val f=fixture("sleep-normalization").jsonArray[0].jsonObject;val d=Wire.json.decodeFromJsonElement<Dataset>(f.getValue("dataset"));val c=Wire.json.decodeFromJsonElement<List<Change>>(f.getValue("expected"))[0]
        val bad=c.copy(payload=c.payload!!.copy(stages=c.payload.stages!!.map{it.copy(type="unknown")}))
        try{Wire.validate(ChangeSet("22222222-2222-4222-8222-222222222222",listOf(bad)),d);fail()}catch(_:RelayFailure){}
    }
}
