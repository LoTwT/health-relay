package app.healthrelay.android

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import java.io.DataInputStream
import java.io.DataOutputStream
import java.math.BigInteger
import java.net.Inet4Address
import java.net.InetAddress
import java.net.Socket
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Principal
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Base64
import java.util.Date
import javax.net.ssl.*
import javax.security.auth.x500.X500Principal

@Serializable data class PairedSender(val pairId:String,val tokenHash:String,val senderId:String,val datasetId:String?,val mode:String)
data class ReceiverUi(val receiving:Boolean=false,val address:String="",val message:String="准备接收",val qr:String?=null,val pairingName:String?=null,val results:List<GroupResult> = emptyList(),val recovery:RecoveryInfo?=null,val counts:Map<String,Int> = emptyMap())
class ReceiverIdentity {
    private val alias="health-relay-tls-v1"
    private val store=KeyStore.getInstance("AndroidKeyStore").apply{load(null)}
    val existed=store.containsAlias(alias)
    init {
        if(!existed){
            val generator=KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC,"AndroidKeyStore")
            generator.initialize(KeyGenParameterSpec.Builder(alias,KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_NONE,KeyProperties.DIGEST_SHA256,KeyProperties.DIGEST_SHA384,KeyProperties.DIGEST_SHA512)
                .setCertificateSubject(X500Principal("CN=health-relay"))
                .setCertificateSerialNumber(BigInteger(128,SecureRandom()).abs().add(BigInteger.ONE))
                .setCertificateNotBefore(Date(System.currentTimeMillis()-60000))
                .setCertificateNotAfter(Date(System.currentTimeMillis()+3653L*24*60*60*1000)).build())
            generator.generateKeyPair()
        }
    }
    val certificate get()=store.getCertificate(alias) as X509Certificate
    val fingerprint get()=sha256(certificate.encoded)
    fun context():SSLContext {
        certificate.checkValidity()
        val manager=object:X509ExtendedKeyManager(){
            override fun getPrivateKey(a:String?)=store.getKey(alias,null) as PrivateKey
            override fun getCertificateChain(a:String?)=arrayOf(certificate)
            override fun getServerAliases(type:String?,issuers:Array<out Principal>?)=arrayOf(alias)
            override fun chooseServerAlias(type:String?,issuers:Array<out Principal>?,socket:Socket?)=if(type=="EC")alias else null
            override fun getClientAliases(type:String?,issuers:Array<out Principal>?)=null
            override fun chooseClientAlias(types:Array<out String>?,issuers:Array<out Principal>?,socket:Socket?)=null
        }
        return SSLContext.getInstance("TLSv1.3").apply{init(arrayOf(manager),null,SecureRandom())}
    }
}
class LanReceiver(private val context:Context,private val journal:ImportJournal,private val health:HealthConnectWriter,private val identity:ReceiverIdentity) {
    private val scope=CoroutineScope(SupervisorJob()+Dispatchers.IO)
    private val mutable=MutableStateFlow(ReceiverUi());val ui=mutable.asStateFlow()
    private val nsd=context.getSystemService(NsdManager::class.java)
    private val connectivity=context.getSystemService(ConnectivityManager::class.java)
    @Volatile private var listener:SSLServerSocket?=null
    @Volatile private var accepted:SSLSocket?=null
    private var job:Job?=null;private var registration:NsdManager.RegistrationListener?=null
    var lastTransportFailure:Exception?=null
        private set
    private var pairSecret:String?=null;private var pairingId:String?=null;private var pairExpiry=0L
    private var confirmation:CompletableDeferred<Boolean>?=null;private var failures=0
    private var receiverId:String="";private var boundAddress:InetAddress?=null
    private var callback:ConnectivityManager.NetworkCallback?=null
    @Volatile internal var requestGeneration=0L
        private set
    @Synchronized private fun activate(generation:Long){requireRelay(generation==requestGeneration,"RECEIVER_STOPPED");journal.allowed=true}
    @Synchronized fun start(){
        val previous=job
        if(previous?.isActive==true){
            if(!journal.allowed){val generation=requestGeneration;scope.launch{previous.join();startIfCurrent(generation)}}
            return
        }
        val generation=++requestGeneration
        job=scope.launch{
        try{
            requireRelay(health.available(),"HEALTH_CONNECT_UNAVAILABLE")
            receiverId=journal.configuration("receiverId")?:newId().also{journal.save("receiverId",it)}
            val ip=wifiAddress()?:throw RelayFailure("WIFI_UNAVAILABLE");boundAddress=ip
            activate(generation)
            journal.inspectRecovery();journal.recover()
            requireRelay(generation==requestGeneration,"RECEIVER_STOPPED")
            val server=(identity.context().serverSocketFactory.createServerSocket(0,1,ip) as SSLServerSocket).apply{enabledProtocols=arrayOf("TLSv1.3");soTimeout=600000;needClientAuth=false}
            listener=server;requireRelay(generation==requestGeneration,"RECEIVER_STOPPED");failures=0
            mutable.value=mutable.value.copy(receiving=true,address="${ip.hostAddress}:${server.localPort}",message="等待 iPhone 连接",recovery=journal.recoveryInfo(),counts=journal.counts())
            if(journal.configuration("pair")==null)showPairing()
            publish(server.localPort);watchNetwork(generation)
            while(journal.allowed){
                val socket=server.accept() as SSLSocket;accepted=socket
                try{socket.soTimeout=5000;socket.enabledProtocols=arrayOf("TLSv1.3");socket.startHandshake();socket.soTimeout=60000;serve(socket)}catch(e:Exception){lastTransportFailure=e;mutable.value=mutable.value.copy(message="连接中断，已保留导入进度")}
                finally{socket.close();accepted=null}
                if(failures>=5)break
            }
        }catch(e:Exception){lastTransportFailure=e;mutable.value=mutable.value.copy(message=(e as? RelayFailure)?.code?:"CONNECTION_INTERRUPTED")}
        finally{closeSockets();journal.allowed=false;mutable.value=mutable.value.copy(receiving=false,qr=null,pairingName=null)}
    }}
    private fun wifiAddress():InetAddress?=connectivity.allNetworks.firstNotNullOfOrNull{n->
        if(connectivity.getNetworkCapabilities(n)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)==true)connectivity.getLinkProperties(n)?.linkAddresses?.firstOrNull{it.address is Inet4Address && !it.address.isLoopbackAddress}?.address else null
    }
    @Synchronized private fun startIfCurrent(generation:Long){if(generation==requestGeneration)start()}
    @Synchronized internal fun restartForNetworkChange(expectedGeneration:Long=requestGeneration):Job? {
        if(expectedGeneration!=requestGeneration)return null
        stop()
        val generation=requestGeneration;val previous=job
        return scope.launch{previous?.join();startIfCurrent(generation)}
    }
    @Synchronized private fun stopIfCurrent(generation:Long){if(generation==requestGeneration)stop()}
    @Synchronized private fun watchNetwork(generation:Long){
        requireRelay(generation==requestGeneration,"RECEIVER_STOPPED")
        val cb=object:ConnectivityManager.NetworkCallback(){override fun onLinkPropertiesChanged(network:Network,linkProperties:android.net.LinkProperties){if(wifiAddress()!=boundAddress){restartForNetworkChange(generation)}};override fun onLost(network:Network){if(wifiAddress()==null)stopIfCurrent(generation)}}
        callback=cb;connectivity.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(),cb)
    }
    private fun publish(port:Int){
        val info=NsdServiceInfo().apply{serviceName="health-relay-${receiverId.take(8)}";serviceType="_healthrelay._tcp.";this.port=port;setAttribute("protocol","1");setAttribute("receiverId",receiverId)}
        val registration=object:NsdManager.RegistrationListener{
            override fun onServiceRegistered(serviceInfo:NsdServiceInfo){}
            override fun onRegistrationFailed(serviceInfo:NsdServiceInfo,errorCode:Int){mutable.value=mutable.value.copy(message="自动发现不可用，可输入接收端地址")}
            override fun onServiceUnregistered(serviceInfo:NsdServiceInfo){}
            override fun onUnregistrationFailed(serviceInfo:NsdServiceInfo,errorCode:Int){}
        };this.registration=registration;nsd.registerService(info,NsdManager.PROTOCOL_DNS_SD,registration)
    }
    fun showPairing(){
        val socket=listener?:return
        pairSecret=randomSecret();pairingId=newId();pairExpiry=System.currentTimeMillis()+300000
        val code=PairingCode(1,receiverId,boundAddress!!.hostAddress!!,socket.localPort,identity.fingerprint,pairingId!!,pairSecret!!)
        mutable.value=mutable.value.copy(qr=Wire.json.encodeToString(code))
        scope.launch{delay(300000);if(System.currentTimeMillis()>=pairExpiry)hidePairing()}
    }
    fun hidePairing(){pairSecret=null;pairingId=null;mutable.value=mutable.value.copy(qr=null)}
    fun confirmPair(accept:Boolean){confirmation?.complete(accept)}
    private fun closeSockets(){
        listener?.let{runCatching{it.close()}};accepted?.let{runCatching{it.close()}};listener=null;accepted=null
        registration?.let{runCatching{nsd.unregisterService(it)}};registration=null
        callback?.let{runCatching{connectivity.unregisterNetworkCallback(it)}};callback=null
        confirmation?.complete(false);hidePairing()
    }
    @Synchronized fun stop(){requestGeneration++;journal.allowed=false;closeSockets();mutable.value=mutable.value.copy(receiving=false,qr=null,pairingName=null)}
    fun cancelPrepared(){scope.launch{journal.cancelPrepared();mutable.value=mutable.value.copy(recovery=journal.recoveryInfo())}}
    fun unpair(){stop();scope.launch{journal.removePair();mutable.value=mutable.value.copy(message="已解绑；已导入记录与账本保留")}}
    fun clearConfirmed(){stop();scope.launch{try{journal.clearConfirmed();mutable.value=mutable.value.copy(message="清理完成；请在 iPhone 按原范围重建",recovery=journal.recoveryInfo(),counts=journal.counts())}catch(e:Exception){mutable.value=mutable.value.copy(message=(e as? RelayFailure)?.code?:"CLEAR_INTERRUPTED",recovery=journal.recoveryInfo())}}}
    private suspend fun serve(socket:SSLSocket){
        val input=DataInputStream(socket.inputStream);val output=DataOutputStream(socket.outputStream)
        var authenticated:PairedSender?=null;var dataset:Dataset?=null
        while(journal.allowed){
            val message=Wire.read(input);val requestId=message["requestId"]?.jsonPrimitive?.content?:throw RelayFailure("INVALID_ENVELOPE")
            Wire.uuid(requestId)
            try{
                requireRelay(message["protocolVersion"]?.jsonPrimitive?.int==1,"PROTOCOL_INCOMPATIBLE")
                val type=message.getValue("type").jsonPrimitive.content
                val result:JsonElement=when(type){
                    "pair"->{
                        requireRelay(authenticated==null,"AUTHENTICATION_FAILED")
                        requireRelay(pairSecret!=null&&message["pairingId"]?.jsonPrimitive?.content==pairingId&&System.currentTimeMillis()<pairExpiry,"PAIRING_EXPIRED")
                        requireRelay(constantEqual(message.getValue("pairingSecret").jsonPrimitive.content,pairSecret!!),"AUTHENTICATION_FAILED")
                        val sender=message.getValue("senderId").jsonPrimitive.content;Wire.uuid(sender)
                        val name=message.getValue("senderName").jsonPrimitive.content;requireRelay(name.isNotBlank()&&name.length<=120)
                        val mode=message.getValue("mode").jsonPrimitive.content;requireRelay(mode in setOf("normal","recovery"))
                        val id=message["datasetId"]?.jsonPrimitive?.contentOrNull;id?.let(Wire::uuid)
                        requireRelay(mode=="recovery"||id!=null)
                        if(mode=="normal"){
                            val state=journal.state();val previous=journal.dataset()
                            requireRelay(state!="RECOVERY_REQUIRED"&&state!="clearing","RECOVERY_REQUIRED")
                            if(state=="cleared")requireRelay(journal.recoveryInfo()?.rebuildPlan?.newDatasetId==id,"RECOVERY_REQUIRED")
                            else if(previous!=null)requireRelay(previous.datasetId==id,"RECOVERY_REQUIRED")
                        }
                        confirmation=CompletableDeferred();mutable.value=mutable.value.copy(pairingName=name)
                        requireRelay(withTimeout(60000){confirmation!!.await()},"PAIRING_REJECTED")
                        requireRelay(pairSecret!=null&&System.currentTimeMillis()<pairExpiry&&journal.allowed,"PAIRING_EXPIRED")
                        val token=randomSecret();val pair=PairedSender(newId(),sha256(token),sender,id,mode)
                        journal.save("pair",Wire.json.encodeToString(pair));hidePairing();mutable.value=mutable.value.copy(pairingName=null)
                        buildJsonObject{put("pairId",pair.pairId);put("pairToken",token);put("receiverId",receiverId);put("mode",mode);put("receiverState",journal.state());put("recoveryInfo",Wire.json.encodeToJsonElement(journal.recoveryInfo()))}
                    }
                    "hello"->{
                        val pair=journal.configuration("pair")?.let{Wire.json.decodeFromString<PairedSender>(it)}?:throw RelayFailure("AUTHENTICATION_FAILED")
                        requireRelay(message["pairId"]?.jsonPrimitive?.content==pair.pairId&&message["senderId"]?.jsonPrimitive?.content==pair.senderId&&message["receiverId"]?.jsonPrimitive?.content==receiverId&&message["mode"]?.jsonPrimitive?.content==pair.mode,"AUTHENTICATION_FAILED")
                        requireRelay(constantEqual(sha256(message.getValue("pairToken").jsonPrimitive.content),pair.tokenHash),"AUTHENTICATION_FAILED")
                        if(pair.mode=="normal"){
                            requireRelay(message["datasetId"]?.jsonPrimitive?.content==pair.datasetId,"AUTHENTICATION_FAILED")
                            val d=Dataset(pair.datasetId!!,message.getValue("historyStart").jsonPrimitive.content,Wire.json.decodeFromJsonElement(message.getValue("sources")))
                            Wire.time(d.historyStart)
                            if(journal.state()=="cleared")journal.bindRebuilt(d)else journal.bind(d)
                            dataset=d
                        }
                        authenticated=pair
                        buildJsonObject{put("protocolVersion",1);put("permissions",Wire.json.encodeToJsonElement(health.permissions()));put("receiverState",journal.state());put("recoveryInfo",Wire.json.encodeToJsonElement(journal.recoveryInfo()))}
                    }
                    else->{
                        val pair=authenticated?:throw RelayFailure("AUTHENTICATION_FAILED")
                        requireRelay(journal.configuration("pair")?.let{Wire.json.decodeFromString<PairedSender>(it).pairId}==pair.pairId,"AUTHENTICATION_FAILED")
                        when(type){
                            "prepareRebuild"->{val plan=Wire.json.decodeFromJsonElement<RebuildPlan>(message.getValue("rebuildPlan"));journal.prepare(plan);mutable.value=mutable.value.copy(recovery=journal.recoveryInfo(),counts=journal.counts());Wire.json.encodeToJsonElement(journal.recoveryInfo())}
                            "applyBatch"->{
                                requireRelay(pair.mode=="normal"&&dataset!=null&&journal.state()=="ready","RECOVERY_REQUIRED")
                                val generation=message.getValue("generationId").jsonPrimitive.content;val batch=message.getValue("batchId").jsonPrimitive.content;Wire.uuid(generation);Wire.uuid(batch)
                                val groups=message.getValue("changeSets").jsonArray;requireRelay(groups.size in 1..25)
                                val ids=groups.map{it.jsonObject["changeSetId"]?.jsonPrimitive?.content?:throw RelayFailure("INVALID_ENVELOPE")};ids.forEach(Wire::uuid);requireRelay(ids.distinct().size==ids.size)
                                val results=groups.mapIndexed{index,raw->
                                    try{journal.apply(Wire.json.decodeFromJsonElement(raw),dataset!!)}catch(e:Exception){GroupResult(ids[index],emptyList(),(e as? RelayFailure)?.code?:if(e is SecurityException)"PERMISSION_REQUIRED" else "IMPORT_RETRYABLE")}
                                }
                                journal.saveGeneration(generation,results)
                                mutable.value=mutable.value.copy(message=if(results.any{it.error!=null||it.entities.any{e->e.status=="partial"}})"部分完成，可重试" else "已写入 Health Connect，请到三星健康查看",results=(mutable.value.results+results).associateBy{it.changeSetId}.values.toList().takeLast(200),counts=journal.counts())
                                buildJsonObject{put("generationId",generation);put("batchId",batch);put("changeSets",Wire.json.encodeToJsonElement(results))}
                            }
                            "finish"->{requireRelay(pair.mode=="normal","RECOVERY_REQUIRED");buildJsonObject{put("generationId",message.getValue("generationId"));put("changeSets",Wire.json.parseToJsonElement(journal.configuration("generation:"+message.getValue("generationId").jsonPrimitive.content)?:"[]"))}}
                            "unpair"->{journal.removePair();buildJsonObject{put("unpaired",true)}}
                            else->throw RelayFailure("PROTOCOL_INCOMPATIBLE")
                        }
                    }
                }
                Wire.write(output,buildJsonObject{put("protocolVersion",1);put("type","result");put("requestId",requestId);put("ok",true);put("result",result)})
                if(type=="unpair")return
            }catch(e:Exception){
                if(e is CancellationException)throw e
                val code=(e as? RelayFailure)?.code?:"INVALID_PAYLOAD"
                if(code in setOf("AUTHENTICATION_FAILED","PAIRING_EXPIRED"))failures++
                Wire.write(output,buildJsonObject{put("protocolVersion",1);put("type","result");put("requestId",requestId);put("ok",false);put("error",buildJsonObject{put("code",code);put("retryable",code in setOf("IMPORT_RETRYABLE","CONNECTION_INTERRUPTED","READBACK_MISMATCH"))})})
                if(failures>=5)return
            }
        }
    }
    companion object {
        fun randomSecret()=Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32).also{SecureRandom().nextBytes(it)})
        fun constantEqual(a:String,b:String)=java.security.MessageDigest.isEqual(a.toByteArray(Charsets.UTF_8),b.toByteArray(Charsets.UTF_8))
    }
}
