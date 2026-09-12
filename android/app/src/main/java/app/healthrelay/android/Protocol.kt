package app.healthrelay.android

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import java.io.DataInputStream
import java.io.DataOutputStream
import java.nio.charset.CodingErrorAction
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.time.Instant
import java.time.format.DateTimeFormatterBuilder
import java.util.UUID

class RelayFailure(val code: String) : Exception(code)
fun requireRelay(condition: Boolean, code: String = "INVALID_PAYLOAD") { if (!condition) throw RelayFailure(code) }
fun sha256(value: String): String = sha256(value.toByteArray(Charsets.UTF_8))
fun sha256(value: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(value).joinToString("") { "%02x".format(it) }
fun newId(): String = UUID.randomUUID().toString()

@Serializable data class Sources(val sleep: String?, val workout: String?)
@Serializable data class Dataset(val datasetId: String, val historyStart: String, val sources: Sources)
@Serializable data class Source(val bundleIdentifier: String, val sourceKey: String, val name: String?, val deviceType: String?, val manufacturer: String?, val model: String?, val timeZone: String?)
@Serializable data class Interval(val start: String, val end: String)
@Serializable data class Stage(val start: String, val end: String, val type: String)
@Serializable data class Statistic(val state: String, val metres: Double? = null, val kcal: Double? = null)
@Serializable data class Payload(
    val start: String, val end: String, val startOffsetSeconds: Int?, val endOffsetSeconds: Int?,
    val source: Source, val recordingMethod: String, val warnings: List<String>,
    val anchorSampleUuid: String? = null, val sampleUuids: List<String>? = null, val stages: List<Stage>? = null,
    val sourceUuid: String? = null, val appleActivityType: String? = null, val exerciseType: String? = null,
    val durationMs: Long? = null, @OptIn(kotlinx.serialization.ExperimentalSerializationApi::class) @kotlinx.serialization.EncodeDefault(kotlinx.serialization.EncodeDefault.Mode.ALWAYS) val indoor: Boolean? = null, val pauses: List<Interval>? = null,
    val distance: Statistic? = null, val activeEnergy: Statistic? = null
)
@Serializable data class Change(val entityId: String, val version: Long, val kind: String, val action: String, val payload: Payload? = null)
@Serializable data class ChangeSet(val changeSetId: String, val changes: List<Change>)
@Serializable data class RebuildPlan(val planId: String, val oldDatasetId: String?, val newDatasetId: String, val historyStart: String, val sources: Sources)
@Serializable data class EntityResult(val entityId: String, val version: Long, val status: String, val children: Map<String,String>)
@Serializable data class GroupResult(val changeSetId: String, val entities: List<EntityResult>, val error: String? = null)
@Serializable data class PairingCode(val protocol: Int, val receiverId: String, val ip: String, val port: Int, val certificateFingerprint: String, val pairingId: String, val pairingSecret: String)
@Serializable data class RecoveryInfo(val datasetId: String?, val historyStart: String?, val sources: Sources?, val rebuildPlan: RebuildPlan?, val rebuildState: String?)

object Wire {
    val json = Json { explicitNulls = true; encodeDefaults = false; ignoreUnknownKeys = false; isLenient = false; allowSpecialFloatingPointValues = false }
    private val timestamp = DateTimeFormatterBuilder().appendInstant(3).toFormatter()
    fun time(value: String): Instant {
        requireRelay(Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z").matches(value))
        val result = try { Instant.parse(value) } catch (_: Exception) { throw RelayFailure("INVALID_PAYLOAD") }
        requireRelay(timestamp.format(result) == value)
        return result
    }
    fun uuid(value: String) { requireRelay(Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}").matches(value)) }
    fun length(n: Int): Int { requireRelay(n in 1..1_048_576, "RECORD_TOO_LARGE"); return n }
    fun read(input: DataInputStream): JsonObject {
        val bytes = ByteArray(length(input.readInt())); input.readFully(bytes)
        val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
        return json.parseToJsonElement(text).jsonObject
    }
    fun write(output: DataOutputStream, message: JsonObject) {
        val bytes = message.toString().toByteArray(Charsets.UTF_8)
        output.writeInt(length(bytes.size)); output.write(bytes); output.flush()
    }
    fun canonical(element: JsonElement): String = when (element) {
        is JsonObject -> element.toSortedMap().entries.joinToString(",", "{", "}") { json.encodeToString(it.key) + ":" + canonical(it.value) }
        is JsonArray -> element.joinToString(",", "[", "]") { canonical(it) }
        else -> element.toString()
    }
    fun digest(group: ChangeSet) = sha256(canonical(json.encodeToJsonElement(group)))
    fun validate(group: ChangeSet, dataset: Dataset) {
        uuid(group.changeSetId); uuid(dataset.datasetId)
        requireRelay(group.changes.isNotEmpty() && group.changes.map { it.entityId }.distinct().size == group.changes.size)
        requireRelay(group.changes.map { it.version }.distinct().size == 1)
        group.changes.forEach { c ->
            requireRelay(c.version > 0 && c.kind in setOf("sleep","workout") && c.action in setOf("upsert","delete"))
            val prefix = "hr1/${dataset.datasetId}/${c.kind}/"
            requireRelay(c.entityId.startsWith(prefix))
            val suffix = c.entityId.removePrefix(prefix)
            if (c.kind == "workout") uuid(suffix) else {
                val parts = suffix.split('/'); requireRelay(parts.size == 3)
                requireRelay(Regex("[0-9a-f]{64}").matches(parts[0])); uuid(parts[1]); requireRelay(parts[2].toLongOrNull()?.toString() == parts[2])
            }
            if (c.action == "delete") { requireRelay(c.payload == null); return@forEach }
            val p = c.payload ?: throw RelayFailure("INVALID_PAYLOAD")
            val start = time(p.start); val end = time(p.end); val length = end.toEpochMilli()-start.toEpochMilli()
            requireRelay(length > 0 && end >= time(dataset.historyStart))
            requireRelay(p.source.bundleIdentifier.isNotBlank() && p.source.bundleIdentifier.length <= 255 && p.source.sourceKey == sha256(p.source.bundleIdentifier))
            requireRelay(p.source.bundleIdentifier == if(c.kind == "sleep") dataset.sources.sleep else dataset.sources.workout, "SOURCE_CONFIG_MISMATCH")
            listOf(p.source.name,p.source.deviceType,p.source.manufacturer,p.source.model,p.source.timeZone).forEach { requireRelay(it == null || (it.isNotBlank() && it.length <= 120)) }
            requireRelay(p.recordingMethod in setOf("automatic","active","manual","unknown"))
            requireRelay(p.warnings.size <= 100 && p.warnings.all { it in warningCodes })
            listOf(p.startOffsetSeconds,p.endOffsetSeconds).forEach { requireRelay(it == null || it in -64800..64800) }
            if (c.kind == "sleep") {
                requireRelay(p.sourceUuid == null && p.durationMs == null && p.distance == null && p.activeEnergy == null)
                val anchor = p.anchorSampleUuid ?: throw RelayFailure("INVALID_PAYLOAD"); uuid(anchor)
                val samples = p.sampleUuids ?: throw RelayFailure("INVALID_PAYLOAD")
                samples.forEach(::uuid)
                requireRelay(samples.isNotEmpty() && samples.size <= 10000 && samples == samples.distinct().sorted() && anchor in samples)
                requireRelay(c.entityId == "$prefix${p.source.sourceKey}/$anchor/${start.toEpochMilli()}")
                val stages = p.stages ?: throw RelayFailure("INVALID_PAYLOAD")
                requireRelay(stages.size in 1..10000 && length <= 129600000)
                var cursor = start
                stages.forEach { s ->
                    val a = time(s.start); val b = time(s.end)
                    requireRelay(a == cursor && b > a && b <= end && s.type in setOf("sleeping","light","deep","rem","awake")); cursor = b
                }
                requireRelay(cursor == end && stages.any { it.type != "awake" })
            } else {
                requireRelay(p.stages == null && p.sampleUuids == null && p.anchorSampleUuid == null)
                val sourceUuid = p.sourceUuid ?: throw RelayFailure("INVALID_PAYLOAD"); uuid(sourceUuid)
                requireRelay(c.entityId == prefix+sourceUuid)
                val duration = p.durationMs ?: throw RelayFailure("INVALID_PAYLOAD")
                requireRelay(duration > 0 && duration <= length+1000 && p.exerciseType in exerciseTypes)
                requireRelay(!p.appleActivityType.isNullOrBlank() && p.appleActivityType.length <= 120)
                val pauses = p.pauses ?: throw RelayFailure("INVALID_PAYLOAD"); requireRelay(pauses.size <= 10000)
                var cursor = start; var paused = 0L
                pauses.forEach { s -> val a=time(s.start); val b=time(s.end); requireRelay(a>=cursor && b>a && b<=end); cursor=b; paused += b.toEpochMilli()-a.toEpochMilli() }
                if (pauses.isNotEmpty()) requireRelay(kotlin.math.abs(length-paused-duration)<=1000)
                validateStatistic(p.distance,"metres"); validateStatistic(p.activeEnergy,"kcal")
            }
        }
    }
    private fun validateStatistic(s: Statistic?, unit: String) {
        requireRelay(s != null); s!!
        val value = if(unit=="metres") s.metres else s.kcal
        requireRelay(if(s.state=="unavailable") s.metres==null && s.kcal==null else s.state=="value" && value!=null && value.isFinite() && value>=0 && (if(unit=="metres") s.kcal==null else s.metres==null))
    }
    val warningCodes = setOf("UNSUPPORTED_SLEEP_VALUE","CONFLICTING_SLEEP_STAGES","SLEEP_SPLIT_FOR_UNCERTAINTY","DEFERRED_OPEN_SLEEP","NO_SLEEP_EVIDENCE","SLEEP_GROUP_TOO_LARGE","DURATION_NOT_FULLY_REPRESENTABLE","DISTANCE_UNAVAILABLE","ACTIVE_ENERGY_UNAVAILABLE","INVALID_DISTANCE","INVALID_ACTIVE_ENERGY","OVERLAPPING_WORKOUTS","INVALID_INTERVAL")
    val exerciseTypes = setOf("WALKING","RUNNING","BIKING","HIKING","SWIMMING_POOL","SWIMMING_OPEN_WATER","STRENGTH_TRAINING","HIGH_INTENSITY_INTERVAL_TRAINING","YOGA","PILATES","ELLIPTICAL","ROWING","STAIR_CLIMBING","STRETCHING","DANCING","BADMINTON","BASKETBALL","BASEBALL","SOFTBALL","SOCCER","FOOTBALL_AMERICAN","FOOTBALL_AUSTRALIAN","RUGBY","TENNIS","TABLE_TENNIS","SQUASH","RACQUETBALL","VOLLEYBALL","HANDBALL","CRICKET","GOLF","BOXING","MARTIAL_ARTS","ROCK_CLIMBING","FENCING","GYMNASTICS","PADDLING","SAILING","SURFING","SKIING","SNOWBOARDING","SKATING","WATER_POLO","SCUBA_DIVING","WHEELCHAIR","OTHER_WORKOUT")
}
