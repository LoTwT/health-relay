package app.healthrelay.android

import android.app.Application
import android.content.Intent
import android.graphics.Bitmap
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.dp
import androidx.health.connect.client.PermissionController
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.room.Room
import com.google.zxing.BarcodeFormat
import com.google.zxing.MultiFormatWriter
import kotlinx.coroutines.flow.StateFlow

class RelayContainer(context:Application){
    private val identity=ReceiverIdentity()
    private val primary=context.getDatabasePath("health-relay.db")
    private val recovery=context.getDatabasePath("health-relay-recovery.db")
    private val existed=primary.exists()
    private val damaged=if(!existed)false else try {
        android.database.sqlite.SQLiteDatabase.openDatabase(primary.path,null,android.database.sqlite.SQLiteDatabase.OPEN_READONLY,
            android.database.DatabaseErrorHandler{throw android.database.sqlite.SQLiteDatabaseCorruptException()}).use{!it.isDatabaseIntegrityOk}
    }catch(_:android.database.sqlite.SQLiteException){true}
    val database=Room.databaseBuilder(context,RelayDatabase::class.java,if(damaged||recovery.exists())recovery.name else primary.name).build()
    val health=HealthConnectWriter(context)
    val journal=ImportJournal(database,health)
    init { kotlinx.coroutines.runBlocking(kotlinx.coroutines.Dispatchers.IO) {
        if((damaged||(!existed&&identity.existed))&&journal.configuration("state")==null)journal.save("state","RECOVERY_REQUIRED")
    } }
    val receiver=LanReceiver(context,journal,health,identity)
}
class RelayApplication:Application(){val container by lazy{RelayContainer(this)}}
class RelayViewModel(application:Application):AndroidViewModel(application){
    val container=(application as RelayApplication).container
    val state:StateFlow<ReceiverUi> = container.receiver.ui
}
class MainActivity:ComponentActivity(){
    override fun onCreate(savedInstanceState:Bundle?){
        super.onCreate(savedInstanceState)
        // Sensitive screens are excluded from screenshots and the recent-apps snapshot.
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        setContent{MaterialTheme{Surface(Modifier.fillMaxSize()){RelayScreen()}}}
    }
    override fun onStop(){if(!isChangingConfigurations)(application as RelayApplication).container.receiver.stop();super.onStop()}
    @Composable private fun RelayScreen(model:RelayViewModel=viewModel()){
        val state by model.state.collectAsStateWithLifecycle()
        var settings by remember{mutableStateOf(false)}
        var clearing by remember{mutableStateOf(false)}
        var forgetting by remember{mutableStateOf(false)}
        val permissions=rememberLauncherForActivityResult(PermissionController.createRequestPermissionResultContract()){}
        val receiver=model.container.receiver
        LazyColumn(Modifier.fillMaxSize().safeDrawingPadding().padding(horizontal=24.dp),verticalArrangement=Arrangement.spacedBy(16.dp)){
            item{Spacer(Modifier.height(12.dp));Text("health-relay",style=MaterialTheme.typography.headlineLarge);Text("iPhone → Health Connect",style=MaterialTheme.typography.bodyLarge)}
            item{Row(horizontalArrangement=Arrangement.spacedBy(12.dp)){FilterChip(!settings,{settings=false},label={Text("接收")});FilterChip(settings,{settings=true;receiver.hidePairing()},label={Text("设置与结果")})}}
            item{Card(Modifier.fillMaxWidth()){Column(Modifier.padding(20.dp),verticalArrangement=Arrangement.spacedBy(8.dp)){Text(state.message,style=MaterialTheme.typography.titleLarge);if(state.address.isNotEmpty())Text("本机地址：${state.address}");Text("保持两端解锁、前台运行，并连接可互通的 Wi-Fi。")}}}
            if(!settings){
                item{Button(onClick={if(state.receiving)receiver.stop()else receiver.start()},Modifier.fillMaxWidth()){Text(if(state.receiving)"停止接收" else "开始接收")}}
                item{OutlinedButton(onClick={permissions.launch(HealthConnectWriter.requestedPermissions)},Modifier.fillMaxWidth()){Text("授权 Health Connect 写入")}}
                if(state.receiving)item{TextButton(onClick={receiver.showPairing()}){Text("显示配对二维码 / 更换发送端")}}
                state.qr?.let{qr->item{
                    val bitmap=remember(qr){qrBitmap(qr)}
                    Image(bitmap.asImageBitmap(),contentDescription="一次性配对二维码",modifier=Modifier.fillMaxWidth().height(300.dp))
                    Text("请用 iPhone 应用扫码；5 分钟有效。更换配对会撤销旧设备认证。")
                }}
                item{Text("写入成功后，请到三星健康检查睡眠会话、阶段、时长、运动与距离。Health Connect 成功不代表三星已经显示。")}
            }else{
                item{Text("权限与隐私",style=MaterialTheme.typography.titleLarge);Text(permissionExplanation)}
                item{OutlinedButton(onClick={startActivity(Intent("android.health.connect.action.HEALTH_CONNECT_SETTINGS"))}){Text("打开 Health Connect 设置")}}
                item{Text("在三星健康的 Health Connect 权限中开启读取睡眠、运动、距离；若提供活动能量读取也可开启。活动能量不等于总能量，三星运动热量可能为空。源时区未知时 Android 14+ 会采用接收设备系统时区，历史日期归属需核对。")}
                item{Text("导入账本：${state.counts.entries.joinToString { "${it.key} ${it.value}" }}")}
                item{Text("数据库缓存：${getDatabasePath("health-relay.db").length()} 字节。历史删除仅按实际收到的事件处理，可能存在遗漏。")}
                state.recovery?.let{info->item{
                    Text("原历史起点：${info.historyStart?:"未知，需在 iPhone 恢复页明确选择"}")
                    Text("睡眠来源：${info.sources?.sleep?:"未选"}\n运动来源：${info.sources?.workout?:"未选"}")
                    info.rebuildPlan?.let{plan->
                        Text("重建起点：${plan.historyStart}\n睡眠来源：${plan.sources.sleep?:"未选"}\n运动来源：${plan.sources.workout?:"未选"}\n状态：${info.rebuildState}")
                        if(info.rebuildState=="prepared")TextButton(onClick={receiver.cancelPrepared()}){Text("取消尚未清理的重建计划")}
                        if(info.rebuildState in setOf("prepared","clearing"))Button(onClick={clearing=true}){Text("确认清除本应用导入并重建")}
                    }
                }}
                item{OutlinedButton(onClick={forgetting=true}){Text("解绑发送端，保留记录")}}
                item{Text("结果详情",style=MaterialTheme.typography.titleLarge)}
                state.results.asReversed().take(200).forEach{result->item{Card(Modifier.fillMaxWidth()){Column(Modifier.padding(12.dp)){
                    Text(result.error?:"修订结果")
                    result.entities.forEach{entity->Text("${entity.status} · ${entity.children.entries.joinToString { "${it.key}: ${it.value}" }}")}
                }}}}
            }
            item{Spacer(Modifier.height(24.dp))}
        }
        state.pairingName?.let{name->AlertDialog(onDismissRequest={receiver.confirmPair(false)},title={Text("允许这台 iPhone 配对？")},text={Text("$name\n仅确认你手中刚刚扫码的设备。新配对会撤销旧 token。")},confirmButton={TextButton(onClick={receiver.confirmPair(true)}){Text("确认配对")}},dismissButton={TextButton(onClick={receiver.confirmPair(false)}){Text("拒绝")}})}
        if(clearing)AlertDialog(onDismissRequest={clearing=false},title={Text("清除本应用导入")},text={Text("将按具体 ID 删除本应用睡眠、运动、距离和活动能量，共 ${state.counts.values.sum()} 个已登记子记录。原起点 ${state.recovery?.historyStart}，重建起点 ${state.recovery?.rebuildPlan?.historyStart}。只能重导当前可读源记录；不可读旧记录可能无法补回。三星已消费副本是否删除需另外核验。")},confirmButton={TextButton(onClick={clearing=false;receiver.clearConfirmed()}){Text("确认清理")}},dismissButton={TextButton(onClick={clearing=false}){Text("取消")}})
        if(forgetting)AlertDialog(onDismissRequest={forgetting=false},title={Text("解绑发送端")},text={Text("立即撤销旧认证，保留健康记录与去重账本。")},confirmButton={TextButton(onClick={forgetting=false;receiver.unpair()}){Text("解绑")}},dismissButton={TextButton(onClick={forgetting=false}){Text("取消")}})
    }
}
private fun qrBitmap(value:String):Bitmap{
    val matrix=MultiFormatWriter().encode(value,BarcodeFormat.QR_CODE,720,720)
    val pixels=IntArray(720*720){i->if(matrix[i%720,i/720])android.graphics.Color.BLACK else android.graphics.Color.WHITE}
    return Bitmap.createBitmap(pixels,720,720,Bitmap.Config.ARGB_8888)
}
private const val permissionExplanation="仅写入已配对 iPhone 的睡眠、运动及源记录已有的距离和活动能量。回读和删除仅限 health-relay 自己的记录。不会修改 Apple Health 或其他来源，不上传云端，不补造缺失健康数值。"
class PermissionRationaleActivity:ComponentActivity(){override fun onCreate(savedInstanceState:Bundle?){super.onCreate(savedInstanceState);setContent{MaterialTheme{Surface(Modifier.fillMaxSize()){Column(Modifier.safeDrawingPadding().padding(24.dp)){Text("health-relay 权限说明",style=MaterialTheme.typography.headlineMedium);Spacer(Modifier.height(20.dp));Text(permissionExplanation)}}}}}}
