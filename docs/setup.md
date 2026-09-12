# 安装与使用

功能、数据语义和权限边界以 [spec](specs/spec.md) 为准；已执行的验证与未通过项见 [验收记录](acceptance.md)。本实现供个人自用验证，尚未完成 iPhone → S24+ 三星健康真机验收。

## 工程与工具链

| 项目 | 锁定配置 |
| --- | --- |
| iOS | Xcode 26.6、Swift 6 语言模式（本机编译器 6.3.3）、UIKit、iOS 26.0+；`ios/HealthRelay.xcodeproj` / shared scheme `HealthRelay` |
| Android | SDK / target 36、minSdk 34、Build-Tools 36.0.0、AGP 9.1.1、Gradle Wrapper 9.3.1、运行 JDK 25；Java / Kotlin 字节码 17 |
| Kotlin / UI | Kotlin 与 Compose 编译插件 2.3.21；稳定 Compose BOM 2026.02.01 |
| Android 数据 | Room 2.8.4 / KSP 2.3.9；Serialization 1.9.0；Coroutines 1.10.2；Health Connect **1.1.0** |
| 配对码 | ZXing Core 3.5.4；无 Web 服务和中继 |

依赖权威位置是 `android/gradle/libs.versions.toml`；JDK 主版本由 `android/gradle/gradle-daemon-jvm.properties` 固定。IDE 的 Gradle JDK 同样选择 25，使用项目 Wrapper；不要用全局 Gradle 代替。`ANDROID_HOME` 指向本机 SDK，绝对路径只放环境变量或未跟踪的 `android/local.properties`。

BOM 2026.08.00 的 Compose 1.12 实际要求 compileSdk 37，构建时已发现并改为上述兼容稳定组合，未提升本期 SDK 基线。[AGP 兼容矩阵](https://developer.android.com/build/releases/agp-9-1-0-release-notes)、[Compose 版本表](https://developer.android.com/develop/ui/compose/bom/bom-mapping)。本机升级步骤仅在 session 提供，不另建项目升级指南。

仓库提交 Xcode 工程；仅在修改工程文件列表或构建配置时，用 XcodeGen 2.46.0 执行 `xcodegen generate --spec ios/project.yml`。普通安装无需安装 XcodeGen。

## iPhone 安装

1. 用 Xcode 打开 `ios/HealthRelay.xcodeproj`，选择 `HealthRelay` scheme。
2. Xcode Settings → Accounts 登录自己的 Apple Account。在 target 的 Signing & Capabilities 选择 Personal Team，保持 `app.healthrelay.ios` 与同一 Team。
3. 连接并解锁 iPhone，信任 Mac；按系统提示打开 Developer Mode。选择 iPhone destination，Build & Run。首次记录 provisioning profile 的到期日期。
4. 应用点击“读取健康权限与来源”。只请求读取睡眠、运动、已有距离和活动能量；Apple Health 原数据不会被修改。授权流程成功或查询为空均不证明读取已授权。
5. 每类选择一个实际可读来源。仅存在一个可识别 Watch 来源时会预选；多个来源仍由用户确认。先确认 Apple Watch 记录已进入 Apple Health。

免费 Personal Team 的 profile 通常 7 天失效；到期后用同一 bundle ID、Team 在 Xcode **覆盖安装**，不要先卸载。可选付费会员不是本应用的必购资格；费用、账号限制及分发边界见 [spec §10](specs/spec.md#10-权限安装资格和费用)。本项目不发布到 App Store / TestFlight。

## Android 安装与固定签名

开发验证：在 `android/` 执行 `./gradlew :app:assembleDebug`。调试 APK 为 `android/app/build/outputs/apk/debug/app-debug.apk`，只用于开发。

长期自用使用自己的固定 release keystore，包名保持 `app.healthrelay.android`。首次实施已在本机私有目录建立个人签名材料；它不进入仓库。请备份私钥和密码，丢失后不能用另一把钥匙覆盖更新既有安装。

使用标准环境变量 `HEALTH_RELAY_KEYSTORE`、`HEALTH_RELAY_STORE_PASSWORD`、`HEALTH_RELAY_KEY_ALIAS`、`HEALTH_RELAY_KEY_PASSWORD`，然后执行 `./gradlew :app:assembleRelease`。也可使用不把密码放入命令行的辅助入口：

```sh
python3 scripts/build-personal-apk.py
```

辅助脚本默认读取当前用户 `Library/Application Support/health-relay/signing/release.jks` 和 `release-password`；可以用 `HEALTH_RELAY_KEYSTORE` / `HEALTH_RELAY_PASSWORD_FILE` 指向自己的私有文件，默认 alias 为 `health-relay`。脚本只构建，不生成、上传或输出私钥。

release APK 位于 `android/app/build/outputs/apk/release/app-release.apk`。在 S24+ 允许 USB 调试并确认电脑，检查设备后安装：

```sh
adb devices -l
adb -s "$HEALTH_RELAY_ANDROID_SERIAL" install -r android/app/build/outputs/apk/release/app-release.apk
```

`HEALTH_RELAY_ANDROID_SERIAL` 必须使用上一步确认的 S24+ 序列号。不要将 debug APK 当作 release 更新安装；签名不同会被系统拒绝。已有真实记录时，不要为解决签名冲突直接卸载。通过文件安装时，仅为实际安装来源开启系统“允许安装未知应用”。不要求三星开发者模式或 Samsung partner 资格。

## 配对与日常同步

1. 两端连接可互通的 IPv4 Wi-Fi，保持前台与解锁。访客 Wi-Fi / AP 隔离可能阻断连接。
2. Android 点击“授权 Health Connect 写入”，再“开始接收”。首次显示一次性二维码。
3. iPhone 扫码；核对三星端申请设备名称并在三星确认。二维码 5 分钟失效，离开配对页也失效。配对使用固定证书 TLS 1.3，不导出二维码密钥、不使用明文或弱口令降级。
4. iPhone 点击“同步”。真正首次点击时固定保存“当时减 30 × 24 小时”的历史起点，以后不随日期移动。每次会先分页读取变化并重新读取已有运动的关联统计。
5. 看两端结果；“已写入 Health Connect”只是回读校验后的导入结果。到三星健康目标日期查看睡眠和运动，完成 [真机验收](acceptance.md#真机验收) 后才有显示通过的证据。

后续只需三星开始接收、iPhone 同步。发现失败可在 iPhone 设置输入三星当前 IP 与端口，仍校验原证书；地址变化本身不需要重新配对。证书不符则停止并核对设备。后台、锁屏或停止操作会关闭连接，未完成状态留待下一次手动同步。iPhone 的未完成读取收束前显示“正在停止同步，请稍候”；收束后才允许重试。Android 的旧网络回调不能撤销停止操作。

三星健康 → 设置 → Health Connect → 应用权限 → Samsung Health：开启**读取**睡眠、运动、距离；若提供活动能量读取也可开启。只打开三星的写权限不能让其消费导入记录。菜单路径随系统变化，可在系统设置搜索 Health Connect。必要时按 Samsung 官方说明检查 Sync now，是否依赖其云同步须另行记录；health-relay 不启用云中继。

## 核对、重试与恢复

- 断线后再次手动同步；重用相同修订 ID / 版本。可选距离或活动能量权限不足时会话可先完成，结果保留部分完成，获权后补写。
- 读取不可见不等于删除。“重新读取并核对历史”按固定下界重新读取并合并，保留远端记录与历史待核对标记。只传播实际收到的 HealthKit 删除事件；事件过期可能留下目标记录。
- 睡眠空档与清醒/细睡眠冲突会拆成多条有证据的连续会话；不把多条称为多晚，不填补未知时长。无睡眠证据的 inBed 不导入。
- 活动能量只写 `ActiveCaloriesBurnedRecord`，不冒充总能量；三星运动热量可能为空。暂停事件不足时保留源时长并提示表示限制。
- 未知历史时区在协议中保留 null；Android 14+ 可能采用目标系统时区。旅行记录日期归属需要在目标检查。

清除重建或更换来源：

1. iPhone 设置准备重建；先读取当前来源，显示固定起点、可读数量、不可读风险。准备计划不会删除记录。
2. 两端配置丢失时，先用 iPhone 的“恢复配对”读取三星保留的配置。原起点确实无法确认时，恢复页要求明确选择起点，不能自动套用最近 30 天。
3. Android 设置核对同一计划、来源、起点与受影响数量，再本机确认清理。清理只按本应用四种记录的具体 ID 执行。失败停在恢复状态，可继续原计划；清理前可取消已准备计划。
4. 清理完成后 Android 重新显示二维码；iPhone 用“恢复配对”取得同一计划的 cleared 凭据，再选择“清理后按原范围重建”。随后用新数据集重新配对并同步。重复采用同一已完成计划会保留当前数据集、版本和进度，不会再次清空账本。
5. 不可读或源端已删除的记录可能无法恢复；三星已消费的副本是否同步删除必须独立核验。不能把 HC 清理成功说成所有三星页面已回滚。

解绑默认保留数据和账本。iPhone 单端忘记设备无法让离线三星立即撤销 token，必要时在三星端完成解绑。数据库丢失或损坏进入恢复模式；损坏数据库保留在应用私有目录，不据此静默清空健康数据。

## 自动化验证入口

在仓库根目录：

```sh
xcodebuild -list -project ios/HealthRelay.xcodeproj
xcodebuild -showdestinations -project ios/HealthRelay.xcodeproj -scheme HealthRelay
xcodebuild test -project ios/HealthRelay.xcodeproj -scheme HealthRelay -destination "$HEALTH_RELAY_IOS_DESTINATION"
```

在 `android/`：

```sh
./gradlew --version
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
./gradlew :app:connectedDebugAndroidTest
```

正常仪器入口运行 Room / TLS 测试，真实 HC 合成测试默认跳过；当前用例数量与实际结果见 [验收记录](acceptance.md#测试证据索引)。仅在**没有个人健康记录的隔离测试设备/模拟器**上，使用英文系统界面运行：

```sh
./gradlew -PhealthRelayAggregateTests=true :app:connectedDebugAndroidTest
```

该配置只给 debug 测试应用增加 READ_SLEEP，测试通过系统权限 UI 获权、写入合成记录、按 DataOrigin 核对聚合并精确清理。普通 debug 和 release 不包含 READ_SLEEP；测试配置不能安装为日常自用版本。共享 fixtures 的绝对合成时间用于契约测试；真实聚合测试将时间平移到测试日前两天，保留阶段、间隔和时长，另测原历史记录回读。

测试产物保留在 Xcode DerivedData 和 Android `app/build/reports` / `app/build/outputs/androidTest-results`，不入库。仅填写脱敏命令结果和版本到验收文档，不上传用户健康截图或原始记录。
