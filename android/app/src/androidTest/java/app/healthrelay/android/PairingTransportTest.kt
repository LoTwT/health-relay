package app.healthrelay.android

import androidx.room.Room
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.DataInputStream
import java.io.DataOutputStream
import java.security.SecureRandom
import java.security.cert.X509Certificate
import javax.net.ssl.*

@RunWith(AndroidJUnit4::class)
class PairingTransportTest {
    @Test fun C20_C23_C25_tlsPairConfirmationTokenRevocationAndStop()=runBlocking {exerciseTransport("normal")}
    @Test fun C35_recoveryTokenCannotImportOrFinish()=runBlocking {exerciseTransport("recovery")}
    @Test fun C20_networkRestartIsCancelledByLaterStop()=runBlocking { exerciseQueuedRestart(stopAgain=true) }
    @Test fun C25_networkRestartResumesWithoutLaterStop()=runBlocking { exerciseQueuedRestart(stopAgain=false) }
    @Test fun C20_callbackFromStoppedListenerCannotRestart()=runBlocking { exerciseQueuedRestart(stopAgain=true,lateCallback=true) }
    private suspend fun exerciseQueuedRestart(stopAgain:Boolean,lateCallback:Boolean=false) {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val db=Room.inMemoryDatabaseBuilder(context,RelayDatabase::class.java).build()
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
        val memory=JournalRecoveryTest.MemoryHealth()
        val gateway=object:HealthGateway by memory {
            override suspend fun permissions():Set<String> {
                if(!entered.isCompleted){entered.complete(Unit);release.await()}
                return emptySet()
            }
        }
        val journal=ImportJournal(db,gateway)
        journal.save("state","RECOVERY_REQUIRED")
        val receiver=LanReceiver(context,journal,HealthConnectWriter(context),ReceiverIdentity())
        try {
            receiver.start();withTimeout(10000){entered.await()}
            val observedGeneration=receiver.requestGeneration
            if(lateCallback)receiver.stop()
            val restart=receiver.restartForNetworkChange(observedGeneration)
            if(stopAgain && !lateCallback)receiver.stop()
            release.complete(Unit);withTimeout(10000){restart?.join()}
            val receiving=withTimeoutOrNull(if(stopAgain)1500 else 10000){receiver.ui.first{it.receiving}}
            if(stopAgain){assertNull("A later stop must invalidate the queued network restart",receiving);assertFalse(journal.allowed)}
            else{assertNotNull("An uninterrupted network restart must actually resume",receiving);assertTrue(journal.allowed)}
        } finally {release.complete(Unit);receiver.stop();delay(100);db.close()}
    }
    private suspend fun exerciseTransport(mode:String) {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val db=Room.inMemoryDatabaseBuilder(context,RelayDatabase::class.java).build()
        val journal=ImportJournal(db,JournalRecoveryTest.MemoryHealth())
        val receiver=LanReceiver(context,journal,HealthConnectWriter(context),ReceiverIdentity())
        try{
            receiver.start()
            val ready=withTimeout(10000){receiver.ui.first{it.qr!=null}}
            val code=Wire.json.decodeFromString<PairingCode>(ready.qr!!)
            val identity=ReceiverIdentity()
            val trust=object:X509TrustManager{
                override fun getAcceptedIssuers()=emptyArray<X509Certificate>()
                override fun checkClientTrusted(chain:Array<out X509Certificate>?,authType:String?)=throw java.security.cert.CertificateException()
                override fun checkServerTrusted(chain:Array<out X509Certificate>?,authType:String?){
                    val leaf=chain?.firstOrNull()?:throw java.security.cert.CertificateException()
                    leaf.checkValidity();if(sha256(leaf.encoded)!=code.certificateFingerprint)throw java.security.cert.CertificateException()
                }
            }
            val tls=SSLContext.getInstance("TLSv1.3").apply{init(null,arrayOf(trust),SecureRandom())}
            val socket=tls.socketFactory.createSocket(code.ip,code.port) as SSLSocket
            socket.use{
                socket.enabledProtocols=arrayOf("TLSv1.3");socket.soTimeout=10000;try{socket.startHandshake()}catch(e:Exception){delay(100);throw AssertionError("server TLS failure: ${receiver.lastTransportFailure}; ${receiver.ui.value.message}",e)}
                assertEquals("TLSv1.3",socket.session.protocol);assertEquals(identity.fingerprint,code.certificateFingerprint)
                val input=DataInputStream(socket.inputStream);val output=DataOutputStream(socket.outputStream)
                val datasetId=newId();val senderId=newId()
                fun request(type:String,fields:JsonObject)=buildJsonObject{put("protocolVersion",1);put("type",type);put("requestId",newId());fields.forEach{(k,v)->put(k,v)}}
                val pair=request("pair",buildJsonObject{put("pairingId",code.pairingId);put("pairingSecret",code.pairingSecret);put("senderId",senderId);put("senderName","Synthetic iPhone");put("mode",mode);put("datasetId",datasetId)})
                Wire.write(output,pair)
                withTimeout(10000){receiver.ui.first{it.pairingName!=null}};receiver.confirmPair(true)
                val response=Wire.read(input);assertTrue(response.getValue("ok").jsonPrimitive.boolean)
                val result=response.getValue("result").jsonObject
                assertNull(receiver.ui.value.qr)
                val hello=request("hello",buildJsonObject{put("pairId",result.getValue("pairId"));put("pairToken",result.getValue("pairToken"));put("senderId",senderId);put("receiverId",code.receiverId);put("mode",mode);put("datasetId",datasetId);put("historyStart","2026-07-01T00:00:00.000Z");put("sources",Wire.json.encodeToJsonElement(Sources(null,"example.synthetic.watch")))})
                Wire.write(output,hello);assertTrue(Wire.read(input).getValue("ok").jsonPrimitive.boolean)
                if(mode=="recovery"){
                    Wire.write(output,request("applyBatch",buildJsonObject{put("generationId",newId());put("batchId",newId());put("changeSets",JsonArray(emptyList()))}))
                    val denied=Wire.read(input);assertFalse(denied["ok"]!!.jsonPrimitive.boolean);assertEquals("RECOVERY_REQUIRED",denied["error"]!!.jsonObject["code"]!!.jsonPrimitive.content)
                    Wire.write(output,request("finish",buildJsonObject{put("generationId",newId())}));assertFalse(Wire.read(input)["ok"]!!.jsonPrimitive.boolean)
                    val plan=RebuildPlan(newId(),null,newId(),"2026-07-01T00:00:00.000Z",Sources(null,"example.synthetic.watch"))
                    repeat(2){Wire.write(output,request("prepareRebuild",buildJsonObject{put("rebuildPlan",Wire.json.encodeToJsonElement(plan))}));assertTrue(Wire.read(input)["ok"]!!.jsonPrimitive.boolean)}
                    assertEquals(plan,journal.recoveryInfo()!!.rebuildPlan)
                    Wire.write(output,request("unpair",buildJsonObject{}));assertTrue(Wire.read(input)["ok"]!!.jsonPrimitive.boolean)
                    assertNull(journal.configuration("pair"));return
                }
                val fixture=Wire.json.parseToJsonElement(InstrumentationRegistry.getInstrumentation().context.assets.open("workout.json").bufferedReader().use{it.readText()}).jsonObject
                val source=Wire.json.decodeFromJsonElement<ChangeSet>(fixture.getValue("group"))
                val good=source.copy(changeSetId=newId(),changes=source.changes.map{it.copy(entityId="hr1/$datasetId/workout/"+it.payload!!.sourceUuid,version=1)})
                val bad=good.copy(changeSetId=newId(),changes=good.changes.map{it.copy(version=0)})
                Wire.write(output,request("applyBatch",buildJsonObject{put("generationId",newId());put("batchId",newId());put("changeSets",Wire.json.encodeToJsonElement(listOf(good,bad)))}))
                val batch=Wire.read(input);assertTrue(batch.getValue("ok").jsonPrimitive.boolean)
                val groups=batch.getValue("result").jsonObject.getValue("changeSets").jsonArray
                assertEquals("applied",groups[0].jsonObject.getValue("entities").jsonArray[0].jsonObject.getValue("status").jsonPrimitive.content)
                assertEquals("INVALID_PAYLOAD",groups[1].jsonObject.getValue("error").jsonPrimitive.content)
                journal.removePair()
                Wire.write(output,request("finish",buildJsonObject{put("generationId",newId())}))
                val rejected=Wire.read(input);assertFalse(rejected.getValue("ok").jsonPrimitive.boolean)
                assertEquals("AUTHENTICATION_FAILED",rejected.getValue("error").jsonObject.getValue("code").jsonPrimitive.content)
                receiver.stop();assertFalse(receiver.ui.value.receiving);assertFalse(journal.allowed)
            }
        }finally{receiver.stop();db.close()}
    }
}
