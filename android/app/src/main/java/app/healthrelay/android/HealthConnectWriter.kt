package app.healthrelay.android

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.*
import androidx.health.connect.client.records.metadata.DataOrigin
import androidx.health.connect.client.records.metadata.Device
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import androidx.health.connect.client.units.Energy
import androidx.health.connect.client.units.Length
import java.time.Instant
import java.time.ZoneOffset
import kotlin.reflect.KClass

class HealthConnectWriter(private val context:Context):HealthGateway {
    private val client by lazy{HealthConnectClient.getOrCreate(context)}
    fun available()=HealthConnectClient.getSdkStatus(context)==HealthConnectClient.SDK_AVAILABLE
    override suspend fun permissions():Set<String> {
        requireRelay(available(),"HEALTH_CONNECT_UNAVAILABLE")
        val granted=client.permissionController.getGrantedPermissions()
        return recordTypes.filter{(_,type)->HealthPermission.getWritePermission(type) in granted}.keys
    }
    override fun validate(change:Change){ImportJournal.desiredChildren(change).forEach{record(change,it)}}
    private fun metadata(c:Change,child:String):Metadata {
        val p=c.payload!!;val s=p.source
        val device=Device(type=if(s.deviceType=="watch")Device.TYPE_WATCH else Device.TYPE_UNKNOWN,manufacturer=s.manufacturer,model=s.model)
        val id=c.entityId+":"+child
        return when(p.recordingMethod){
            "automatic"->Metadata.autoRecorded(device,id,c.version)
            "active"->Metadata.activelyRecorded(device,id,c.version)
            "manual"->Metadata.manualEntry(id,c.version,device)
            else->Metadata.unknownRecordingMethod(id,c.version,device)
        }
    }
    fun record(c:Change,child:String):Record {
        val p=c.payload!!;val start=Wire.time(p.start);val end=Wire.time(p.end)
        val a=p.startOffsetSeconds?.let(ZoneOffset::ofTotalSeconds);val b=p.endOffsetSeconds?.let(ZoneOffset::ofTotalSeconds)
        val metadata=metadata(c,child)
        return when(child){
            "distance"->DistanceRecord(start,a,end,b,Length.meters(p.distance!!.metres!!),metadata)
            "active-energy"->ActiveCaloriesBurnedRecord(start,a,end,b,Energy.kilocalories(p.activeEnergy!!.kcal!!),metadata)
            else->if(c.kind=="sleep") SleepSessionRecord(start,a,end,b,metadata,title="Apple Health 睡眠",notes="由 health-relay 导入；空档与不确定区间已拆分。",stages=p.stages!!.map{SleepSessionRecord.Stage(Wire.time(it.start),Wire.time(it.end),stageTypes.getValue(it.type))})
            else ExerciseSessionRecord(start,a,end,b,metadata,exerciseTypes.getValue(p.exerciseType!!),title="Apple Health ${p.appleActivityType}",notes="Apple Health 运动时长：${p.durationMs!!/1000} 秒；类型：${p.appleActivityType}。活动能量不代表总能量。",segments=p.pauses!!.map{ExerciseSegment(Wire.time(it.start),Wire.time(it.end),ExerciseSegment.EXERCISE_SEGMENT_TYPE_PAUSE)})
        }
    }
    private val recentRecordIds=linkedMapOf<String,String>()
    override suspend fun write(changes:List<Pair<Change,String>>){
        val records=changes.map{record(it.first,it.second)}
        val result=client.insertRecords(records)
        records.zip(result.recordIdsList).forEach{(record,id)->recentRecordIds[record.metadata.clientRecordId!!]=id}
        while(recentRecordIds.size>200)recentRecordIds.remove(recentRecordIds.keys.first())
    }
    private suspend fun <T:Record> read(type:KClass<T>,start:Instant=Instant.EPOCH,end:Instant=Instant.now().plusSeconds(86400)):List<T> {
        val records=mutableListOf<T>();var token:String?=null
        do{
            val response=client.readRecords(ReadRecordsRequest(type,TimeRangeFilter.between(start,end),dataOriginFilter=setOf(DataOrigin(context.packageName)),pageSize=500,pageToken=token))
            records+=response.records;token=response.pageToken
        }while(!token.isNullOrEmpty())
        return records
    }
    var lastReadbackIssue:String?=null
    override suspend fun verify(change:Change,child:String):Boolean {
        lastReadbackIssue=null
        val expected=record(change,child);val p=change.payload!!
        val type=recordTypes.getValue(ImportJournal.childType(change,child))
        val actual=read(type,Wire.time(p.start),Wire.time(p.end)).firstOrNull{it.metadata.clientRecordId==expected.metadata.clientRecordId}?:run{
            val id=recentRecordIds[expected.metadata.clientRecordId]
            lastReadbackIssue=if(id==null)"RECORD_NOT_VISIBLE" else try{client.readRecord(type,id);"FILTER_EMPTY_ID_READ_SUCCEEDED"}catch(e:Exception){"RECORD_NOT_VISIBLE_"+e.javaClass.simpleName}
            return false
        }
        if(actual.metadata.clientRecordVersion!=change.version){lastReadbackIssue="VERSION_MISMATCH";return false}
        if(actual.metadata.dataOrigin.packageName!=context.packageName){lastReadbackIssue="ORIGIN_MISMATCH";return false}
        val same=equivalent(expected,actual);if(!same)lastReadbackIssue="CONTENT_MISMATCH";return same
    }
    private fun equivalent(a:Record,b:Record):Boolean {
        return when {
            a is SleepSessionRecord&&b is SleepSessionRecord->(a.startTime==b.startTime&&a.endTime==b.endTime&&(a.startZoneOffset==null||a.startZoneOffset==b.startZoneOffset)&&(a.endZoneOffset==null||a.endZoneOffset==b.endZoneOffset))&&a.stages==b.stages
            a is ExerciseSessionRecord&&b is ExerciseSessionRecord->(a.startTime==b.startTime&&a.endTime==b.endTime&&(a.startZoneOffset==null||a.startZoneOffset==b.startZoneOffset)&&(a.endZoneOffset==null||a.endZoneOffset==b.endZoneOffset))&&a.exerciseType==b.exerciseType&&a.segments==b.segments&&a.notes==b.notes
            a is DistanceRecord&&b is DistanceRecord->(a.startTime==b.startTime&&a.endTime==b.endTime&&(a.startZoneOffset==null||a.startZoneOffset==b.startZoneOffset)&&(a.endZoneOffset==null||a.endZoneOffset==b.endZoneOffset))&&kotlin.math.abs(a.distance.inMeters-b.distance.inMeters)<0.000001
            a is ActiveCaloriesBurnedRecord&&b is ActiveCaloriesBurnedRecord->(a.startTime==b.startTime&&a.endTime==b.endTime&&(a.startZoneOffset==null||a.startZoneOffset==b.startZoneOffset)&&(a.endZoneOffset==null||a.endZoneOffset==b.endZoneOffset))&&kotlin.math.abs(a.energy.inKilocalories-b.energy.inKilocalories)<0.000001
            else->false
        }
    }
    override suspend fun delete(child:ChildRow){client.deleteRecords(recordTypes.getValue(child.type),recordIdsList=emptyList(),clientRecordIdsList=listOf(child.clientId))}
    override suspend fun absent(child:ChildRow)=read(recordTypes.getValue(child.type)).none{it.metadata.clientRecordId==child.clientId}
    override suspend fun ownRecords(type:String):List<ChildRow> = read(recordTypes.getValue(type)).mapNotNull { record ->
        val id=record.metadata.clientRecordId
        if(id?.startsWith("hr1/")==true)ChildRow(id,id.substringBeforeLast(':'),type,record.metadata.clientRecordVersion,true) else null
    }
    companion object {
        val recordTypes:Map<String,KClass<out Record>> = mapOf("sleep" to SleepSessionRecord::class,"exercise" to ExerciseSessionRecord::class,"distance" to DistanceRecord::class,"active-energy" to ActiveCaloriesBurnedRecord::class)
        val requestedPermissions=recordTypes.values.map{HealthPermission.getWritePermission(it)}.toSet()
        val stageTypes=mapOf("sleeping" to SleepSessionRecord.STAGE_TYPE_SLEEPING,"light" to SleepSessionRecord.STAGE_TYPE_LIGHT,"deep" to SleepSessionRecord.STAGE_TYPE_DEEP,"rem" to SleepSessionRecord.STAGE_TYPE_REM,"awake" to SleepSessionRecord.STAGE_TYPE_AWAKE)
        val exerciseTypes=mapOf(
            "WALKING" to ExerciseSessionRecord.EXERCISE_TYPE_WALKING,
            "RUNNING" to ExerciseSessionRecord.EXERCISE_TYPE_RUNNING,
            "BIKING" to ExerciseSessionRecord.EXERCISE_TYPE_BIKING,
            "HIKING" to ExerciseSessionRecord.EXERCISE_TYPE_HIKING,
            "SWIMMING_POOL" to ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_POOL,
            "SWIMMING_OPEN_WATER" to ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_OPEN_WATER,
            "STRENGTH_TRAINING" to ExerciseSessionRecord.EXERCISE_TYPE_STRENGTH_TRAINING,
            "HIGH_INTENSITY_INTERVAL_TRAINING" to ExerciseSessionRecord.EXERCISE_TYPE_HIGH_INTENSITY_INTERVAL_TRAINING,
            "YOGA" to ExerciseSessionRecord.EXERCISE_TYPE_YOGA,
            "PILATES" to ExerciseSessionRecord.EXERCISE_TYPE_PILATES,
            "ELLIPTICAL" to ExerciseSessionRecord.EXERCISE_TYPE_ELLIPTICAL,
            "ROWING" to ExerciseSessionRecord.EXERCISE_TYPE_ROWING,
            "STAIR_CLIMBING" to ExerciseSessionRecord.EXERCISE_TYPE_STAIR_CLIMBING,
            "STRETCHING" to ExerciseSessionRecord.EXERCISE_TYPE_STRETCHING,
            "DANCING" to ExerciseSessionRecord.EXERCISE_TYPE_DANCING,
            "BADMINTON" to ExerciseSessionRecord.EXERCISE_TYPE_BADMINTON,
            "BASKETBALL" to ExerciseSessionRecord.EXERCISE_TYPE_BASKETBALL,
            "BASEBALL" to ExerciseSessionRecord.EXERCISE_TYPE_BASEBALL,
            "SOFTBALL" to ExerciseSessionRecord.EXERCISE_TYPE_SOFTBALL,
            "SOCCER" to ExerciseSessionRecord.EXERCISE_TYPE_SOCCER,
            "FOOTBALL_AMERICAN" to ExerciseSessionRecord.EXERCISE_TYPE_FOOTBALL_AMERICAN,
            "FOOTBALL_AUSTRALIAN" to ExerciseSessionRecord.EXERCISE_TYPE_FOOTBALL_AUSTRALIAN,
            "RUGBY" to ExerciseSessionRecord.EXERCISE_TYPE_RUGBY,
            "TENNIS" to ExerciseSessionRecord.EXERCISE_TYPE_TENNIS,
            "TABLE_TENNIS" to ExerciseSessionRecord.EXERCISE_TYPE_TABLE_TENNIS,
            "SQUASH" to ExerciseSessionRecord.EXERCISE_TYPE_SQUASH,
            "RACQUETBALL" to ExerciseSessionRecord.EXERCISE_TYPE_RACQUETBALL,
            "VOLLEYBALL" to ExerciseSessionRecord.EXERCISE_TYPE_VOLLEYBALL,
            "HANDBALL" to ExerciseSessionRecord.EXERCISE_TYPE_HANDBALL,
            "CRICKET" to ExerciseSessionRecord.EXERCISE_TYPE_CRICKET,
            "GOLF" to ExerciseSessionRecord.EXERCISE_TYPE_GOLF,
            "BOXING" to ExerciseSessionRecord.EXERCISE_TYPE_BOXING,
            "MARTIAL_ARTS" to ExerciseSessionRecord.EXERCISE_TYPE_MARTIAL_ARTS,
            "ROCK_CLIMBING" to ExerciseSessionRecord.EXERCISE_TYPE_ROCK_CLIMBING,
            "FENCING" to ExerciseSessionRecord.EXERCISE_TYPE_FENCING,
            "GYMNASTICS" to ExerciseSessionRecord.EXERCISE_TYPE_GYMNASTICS,
            "PADDLING" to ExerciseSessionRecord.EXERCISE_TYPE_PADDLING,
            "SAILING" to ExerciseSessionRecord.EXERCISE_TYPE_SAILING,
            "SURFING" to ExerciseSessionRecord.EXERCISE_TYPE_SURFING,
            "SKIING" to ExerciseSessionRecord.EXERCISE_TYPE_SKIING,
            "SNOWBOARDING" to ExerciseSessionRecord.EXERCISE_TYPE_SNOWBOARDING,
            "SKATING" to ExerciseSessionRecord.EXERCISE_TYPE_SKATING,
            "WATER_POLO" to ExerciseSessionRecord.EXERCISE_TYPE_WATER_POLO,
            "SCUBA_DIVING" to ExerciseSessionRecord.EXERCISE_TYPE_SCUBA_DIVING,
            "WHEELCHAIR" to ExerciseSessionRecord.EXERCISE_TYPE_WHEELCHAIR,
            "OTHER_WORKOUT" to ExerciseSessionRecord.EXERCISE_TYPE_OTHER_WORKOUT
        )
    }
}
