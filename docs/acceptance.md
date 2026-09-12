# MVP 实施与验收记录

日期：2026-09-12（Asia/Shanghai）。需求基线：[spec v1.3](specs/spec.md)。本文件只维护实施映射、实测结果和缺口，不重复定义验收标准。

**结论：双端实现及自动化验证已交付，完整 MVP 尚未验收通过。** iPhone 签名与真机授权受阻；没有连接用户 iPhone 17、Apple Watch Series 11 或 S24+。三星健康的会话、阶段、时长、距离和更新/删除传播均待验收。模拟器 Health Connect 成功不能关闭该阻断项。

## 实现入口

| 职责 | 权威实现 |
| --- | --- |
| UIKit 应用、授权、来源选择、扫描、结果、恢复 | [iOS](../ios/HealthRelay/RelayViewController.swift)、[场景生命周期](../ios/HealthRelay/AppDelegate.swift) |
| HealthKit 分页、关联统计、UUID 复读 | [HealthKitReader](../ios/HealthRelay/HealthKitReader.swift) |
| 睡眠规范化、运动映射、确定性身份 | [Normalizer](../ios/HealthRelay/Normalizer.swift) |
| 固定历史、anchor、Outbox、补偿删除、历史核对 | [SyncStore](../ios/HealthRelay/SyncStore.swift)、[SyncCoordinator](../ios/HealthRelay/SyncCoordinator.swift) |
| JSON / Int64 / 帧契约 | [契约说明](../protocol/README.md)、[schema](../protocol/v1.schema.json)、[Swift](../ios/HealthRelay/Protocol.swift)、[Kotlin](../android/app/src/main/java/app/healthrelay/android/Protocol.kt) |
| 指纹固定、TLS 1.3、配对、发现与认证 | [发送端](../ios/HealthRelay/LANClient.swift)、[接收端](../android/app/src/main/java/app/healthrelay/android/LanReceiver.kt) |
| Room 修订账本、部分完成、重建 | [ImportJournal](../android/app/src/main/java/app/healthrelay/android/ImportJournal.kt)、[Room schema](../android/app/schemas/app.healthrelay.android.RelayDatabase/1.json) |
| Health Connect 四类记录、自身来源回读、精确删除 | [HealthConnectWriter](../android/app/src/main/java/app/healthrelay/android/HealthConnectWriter.kt) |
| Compose 接收、权限、设置和结果 | [MainActivity](../android/app/src/main/java/app/healthrelay/android/MainActivity.kt) |

## 测试证据索引

- **SC**：[Swift ContractTests](../ios/HealthRelayTests/ContractTests.swift)，7 个测试，含共享合成输入的完整睡眠输出比较、运动、异常契约、Int64/null、DST、固定证书指纹/有效期/用途。
- **SR**：[Swift RecoveryTests](../ios/HealthRelayTests/RecoveryTests.swift)，26 个测试，真实 SQLite、合成 HealthKit 页面和可注入的读源/传输边界；覆盖发送前可读性和跨轮恢复。
- **KC**：[Kotlin ContractTest](../android/app/src/test/java/app/healthrelay/android/ContractTest.kt)，6 个测试，共用 [fixtures](../fixtures/README.json)。18 个睡眠场景、16 个坏契约场景；Kotlin 验证目标 payload 与时长，Swift 执行源规范化。两端没有各自复制另一组合成数据。
- **JR**：[JournalRecoveryTest](../android/app/src/androidTest/java/app/healthrelay/android/JournalRecoveryTest.kt)，13 个仪器测试，真实 Room + 内存 HealthGateway；证明账本算法，不证明系统 HC 或三星行为。
- **PT**：[PairingTransportTest](../android/app/src/androidTest/java/app/healthrelay/android/PairingTransportTest.kt)，5 个仪器测试，真实 Android Keystore / SSLServerSocket / TLS 配对、hello、合法与坏组同批、撤销 token、停止监听、recovery token 权限隔离；用合成协议客户端模拟用户确认，不是 iPhone 跨端实测。
- **HC**：[HealthConnectIntegrationTest](../android/app/src/androidTest/java/app/healthrelay/android/HealthConnectIntegrationTest.kt)，3 个可选仪器测试，真实系统 HC，合成数据。仅测试配置申请 READ_SLEEP。覆盖重复写入、逐条自身来源回读、阶段、空档/awake 聚合、运动三类子记录、早于授权前 30 天的历史及精确删除。

TLS fixtures 是公开合成证书，不含私钥。fixtures 与脚本不读取用户健康数据；生成方式见 [脚本](../scripts/make-fixtures.py)。测试日志和截图不进入仓库。

## 命令与结果

| 实际执行命令 / 环境 | 结果与可证明范围 |
| --- | --- |
| `git status --short --branch`、`git log -1` | 实施开始时 main 干净，已有内容为项目规则和规格；当前提交状态以 Git 历史为准。 |
| `xcodebuild -version`、`swift --version` | Xcode 26.6 / 17F113；Swift 6.3.3，工程使用 Swift 6 语言模式。 |
| `android --version`、`android --sdk="$ANDROID_HOME" sdk list`、`adb version` | Android CLI 1.0.16261425；cmdline-tools 23.0，Platform 36 rev2、Build-Tools 36.0.0；ADB 37.0.1。 |
| `android/gradlew -p android --version` | Gradle 9.3.1；Launcher JVM 25.0.3，Daemon JVM criteria Java 25。实际构建与 IDE JBR 使用同一正式 JDK。 |
| `xcodebuild -list -project ios/HealthRelay.xcodeproj` | 成功，shared scheme `HealthRelay`。 |
| `xcodebuild -showdestinations -project ios/HealthRelay.xcodeproj -scheme HealthRelay` | 成功，列出本机可用模拟器。 |
| `xcodebuild test -project ios/HealthRelay.xcodeproj -scheme HealthRelay -destination 'platform=iOS Simulator,id=D91B695C-DB9B-4C10-B9A5-FD8BCCED45AB' -parallel-testing-enabled NO` | iPhone 17 Pro / iOS 26.5 模拟器，33 测试通过；包含构建、测试应用安装。不是用户 iPhone 安装或真实 HealthKit 授权证据。 |
| `android/gradlew -p android :app:testDebugUnitTest :app:lintDebug :app:assembleDebug` | 构建与 6 项单元测试通过；lint 0 错误，13 个依赖新版本提示。兼容版本固定，未为消除提示提升 spec SDK 基线。 |
| `android/gradlew -p android :app:connectedDebugAndroidTest` | 普通测试入口；3 项真实 HC 测试按设计跳过，13 项 Room 与 5 项 TLS/接收生命周期测试通过；本轮在独立副本将 applicationId 改为 `app.healthrelay.android.ablation`，保留既有个人签名安装。此入口本身不能证明 HC 聚合通过。 |
| `android/gradlew -p android -PhealthRelayAggregateTests=true :app:connectedDebugAndroidTest` | API 36 / `medium_phone`，系统 HC 360527520：此前实施验收为 16 测试通过、0 跳过，含真实 HC 3 项；本轮修复未重跑该可选入口。授权使用英文系统权限界面；数据在 finally 中精确删除。 |
| 同一可选 HC 入口，API 34 / Pixel_3a_API_34_extension_level_7_arm64-v8a | 近期睡眠写入、聚合及 TLS 已通过；新增历史 workout 回读断言后失败，`RECORD_NOT_VISIBLE_RemoteException`。系统 HC 340818080。保留此兼容性失败，不用 API 36 通过覆盖它。 |
| `python3 scripts/build-personal-apk.py` | 固定个人密钥签名 release APK 构建通过。产物及覆盖安装方式见 [setup](setup.md#android-安装与固定签名)。 |
| `apksigner verify --print-certs android/app/build/outputs/apk/release/app-release.apk` | 签名有效；APK 已在 API 36 模拟器安装并启动。`apkanalyzer manifest permissions` 确认正式包仅四项 HC 写权限，没有 READ_SLEEP / READ_HISTORY；证书 SHA-256 `7666c6275957ad9b3d3f060a4411a0e88b71ac6d3e9ea450e0a6a7e3dc370fe6`。只记录公开指纹。 |
| `xcodebuild build -project ios/HealthRelay.xcodeproj -scheme HealthRelay -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO` | 本轮 iPhoneOS 目标构建通过；未签名，不能替代 iPhone 签名安装。 |
| `security find-identity -v -p codesigning`；`xcodebuild ... -destination 'generic/platform=iOS' build` | 0 个有效签名身份；真机构建失败：requires a development team。尚无可供 iPhone 安装的签名产物或 profile 到期日。 |
| `adb devices -l` | 只看到本次启动的模拟器，没有 S24+。 |

补充检查：本轮普通入口的 XML 报告为 21 测试、0 失败、3 跳过（以 XML 为准，控制台进度另计 skipped）；以 XML 结果为准。iOS 空状态界面已在模拟器安装、启动并人工查看，按钮及说明可见，无布局截断；这不证明授权后各页面或真机流程。

详细产物：Xcode DerivedData 的 `.xcresult`；Android `app/build/test-results`、`app/build/reports` 和 `app/build/outputs/androidTest-results`。实施终端输出在本机 `/tmp/health-relay-*.log`；修复的命令、红/绿测试、变体 patch 与 JSON/XML 结果另存于本机 `~/.codex/visualizations/2026/09/12/01a09518-bfa5-7532-bd7f-81ff6de5e943/ablation-fix/`。临时文件不保证长期保留。此表是脱敏持久证据，日志不是版本库内容。

## C01–C35 追踪

“自动化通过”仅指本行列出的测试范围；“待真机”始终保留 spec 所要求的设备行为。未覆盖的触发条件明确列出，不能因相邻用例通过视为全项通过。

| 条目 | 实现 / 自动化证据 | 状态及剩余验收 |
| --- | --- | --- |
| C01 | SyncStore 内容差分；SR unchanged、等价源变化复用原修订；JR 三次重放；HC 三次 ID 不增长 | 自动化通过；三星数量与日常未变化显示待真机。 |
| C02 | attempted Outbox + Journal receipt；SR 身份变更组在 pending/retryable/partial 及 SQLite 重开后复用 ID/版本/内容；JR 丢回执重发只一次写入 | 自动化通过；真实网络丢回执待真机。 |
| C03 | 每轮 UUID 重读关联统计；JR 新版与 unavailable 保留；HC workout 版本更新 | 自动化通过；真实迟到统计及三星更新待真机。 |
| C04 | 明确删除、四类具体 client ID；JR 墓碑；HC 精确删除 | 自动化通过；其他来源保留与三星消费副本删除待真机。 |
| C05 | 睡眠集合差分，旧 remote 与 attempted 身份独立保存；SR 已确认/未确认旧片段及暂缓替换上下文不丢失 | 自动化通过；多晚合并/删除完整真机组合待测。 |
| C06 | Normalizer 连续跨午夜；SC/KC `C06` | 合成通过；三星会话/时长待真机。 |
| C07 | inBed 不参与目标边界；SC/KC `C07` | 合成通过；三星无重复待真机。 |
| C08 | unspecified → sleeping，inBed-only 跳过；SC/KC `C08` | 合成通过；目标显示待真机。 |
| C09 | 重复去重、细阶段降级、unknown 拆分；SC/KC `C09` | 合成通过；三星细阶段待真机。 |
| C10 | 30 分钟阈值、开放组延后、异常组限制；SC/KC `C10`、SR 暂缓/拒绝不误删且无关组继续 | 合成通过；真实晚到阶段待真机。 |
| C11 | UTC 毫秒与两端 offset；SC DST/null、KC null | 协议通过；HC 会为未知 offset 采用系统值，三星旅行日期待核对。 |
| C12 | 单类来源配置、接收端再次校验；SC 来源隔离 | 自动化通过；双 Watch 与三星其他来源待真机。 |
| C13 | 保留源 duration、真实暂停区间；SC workout；HC workout 回读 | 自动化通过；三星暂停消费与时长待真机。 |
| C14 | 无解释事件不造 pause，warning / 源时长详情；SC | 合成通过；UI 与三星具体损失待真机。 |
| C15 | unavailable 与 0 分离，活动能量专用记录；SC/KC、HC 三子记录 | 自动化通过；三星热量边界单列，禁止视作总能量。 |
| C16 | 完整固定运动映射，未知游泳/运动 → OTHER；SC | 合成通过；常见运动三星类型待真机。 |
| C17 | 发前复读依赖、不可读阻止 upsert；SR 实际协调器在 UUID 不可读时零健康帧、恢复可读后发送 | 合成通过；真实 HealthKit 撤销/恢复授权待真机。 |
| C18 | mandatory 权限按修订组隔离；JR 权限失败后继续 | 内存网关通过；真实撤销 WRITE_SLEEP 及独立运动组合待测。 |
| C19 | 子记录版本/完成状态持久化；JR 只补缺项；HC 有权写入回读 | 部分权限恢复算法通过；真实系统撤销/再授权待测。 |
| C20 | 前台生命周期、关闭阻塞 socket、串行账本、1/2/4 秒重试；KC 半帧、JR 写后崩溃/IPC/回读不符保留 payload 并恢复、PT 停止 | 已测触发通过；进程强杀、锁屏、Wi-Fi 中断、Activity 重建完整组合待测。 |
| C21 | 先解析信封，再逐组解码；PT 合法与坏组同一真实 TLS 批次 | 自动化通过；坏组不导致好组丢失。 |
| C22 | 同组内容 hash、版本栅栏、永久墓碑；JR 冲突/旧版本/旧 upsert | 自动化通过。 |
| C23 | 两端严格语义/帧限制；SC/KC 16 坏契约、Int64/null；SC 证书指纹/过期/用途；PT token | 自动化通过；真实 iPhone ↔ Android TLS 互操作待测。 |
| C24 | 手动 IP 复用相同 NWConnection TLS/hello | 实现；Bonjour 失败后的手动真机导入待测。 |
| C25 | 网络地址变化重绑定/NSD，二维码失效，替换与解绑撤销 token；PT token 撤销 | token、正常重启及停止代次测试通过；二维码自然到期、实际 IP 变化待测。 |
| C26 | DB 丢失/损坏隔离恢复，anchor 重读不推删；SR 丢 DB、JR orphan | 合成通过；签名覆盖保留、真实损坏/旧历史 orphan 扫描待测。 |
| C27 | 双端持久计划、本机确认、精确扫描自身记录；JR prepare/clear/bind | 算法通过；S24+ 其他来源不变与清理确认待真机。 |
| C28 | 首次固定起点、相交会话完整、deferred 再算；SC/KC、SR 固定起点及无新 anchor 时关闭 deferred | 合成通过；连续多日不开与真实迟到样本待真机。 |
| C29 | 重建采用原范围；SR/JR history guard（新 planId 也不能绕过）；HC API 36 历史 workout | API 36 通过；API 34 旧组件回读失败，S24+ 历史能力待确认。 |
| C30 | SC/KC 20 分钟/1 毫秒空档及真实 awake；HC 每场景 7,200,000 ms | API 36 真实 HC 聚合通过；三星不能因合并多计时长，待真机。 |
| C31 | 同 UUID 不同 start 唯一 ID、冲突拆分；SC/KC、HC 实际片段合并/精确删除/聚合、SR 旧身份保留 | 自动化通过；三星冲突消失后的传播待真机。 |
| C32 | 页内删除优先、依赖 outbox 作废再推进 anchor；SR same-page delete | 合成通过；真实延后样本删除待真机。 |
| C33 | attempted 历史保留、更高版本补偿、未知 ID 墓碑；SR/JR | 合成通过；真正乱序网络到达待真机。 |
| C34 | 模拟不可读保留目标，独立历史状态；SR missing visibility | 合成通过，无需等待事件真实过期；实际权限恢复待真机。 |
| C35 | 原计划幂等、历史不符零清理、clearing/cleared 可恢复；JR partial clear、SR 重建（含重复采用、错误旧数据集零清理）、PT recovery 禁止 import/finish 及幂等 prepare | 已测算法通过；双端同时丢失的设备交互待真机。 |

## 消融 review 修复记录

本轮修复两类已复现缺陷，不改变 spec 的数据语义或协议版本：

- **拒绝/暂缓被误作删除**：Normalizer 返回拒绝原因与依赖 UUID；SyncCoordinator 将受阻范围传入 SyncStore。整个关联组暂停，保留已确认及可能已送达的旧身份，不重放旧缓存。未完成的旧锚上下文持久保留，下一轮和重启后仍可重算；解除暂缓、修正数据或明确删除后继续处理，独立组不受阻。
- **未确认重组反复分配版本**：差分包含已确认、已尝试及旧修订组的关联身份。若完整 action/payload 集合等于既有队列，复用其原 ID、版本、内容及 attempted 标记；仅有源表示变化、规范化结果相同时也复用。实际内容变化仍产生更高版本，并补偿可能存在的旧身份。

先将 review 探针转为正式测试，仅加入可注入的 HealthReading / RelayTransport / 时钟 / 配对读取边界，再运行尚未修复的业务逻辑：21 项 Swift 测试中 4 项失败，分别为延后睡眠、超限睡眠、无效运动误删和重组改版本。随后补测并复现了重启后丢失旧锚上下文、等价规范化结果分配新版本两条同类路径。最终 26 项 Swift 测试通过；新用例还验证解除阻塞后的实际更新/删除，防止以永久停发掩盖问题。

同类扫描覆盖两个生产 reconcile 调用点，以及睡眠暂缓、异常区间、36 小时/阶段数上限和运动无效/未来结束时间的输出路径。以上拒绝/暂缓路径统一保留旧目标；有效输入形成的空结果仍按 spec 处理，例如明确源删除、无睡眠证据或冲突拆分。固定历史边界、来源过滤、inBed 与未知值的规范化规则保持原定义。

回归入口仍为本文件记录的 `xcodebuild test` 和 `:app:connectedDebugAndroidTest`。Android 新增测试使用真实 Room + 内存 HealthGateway：回读不符不能完成 journal 或丢弃 payload，恢复后可收敛；新的 planId 也不能改变可信历史起点或触发清理。它们不证明真实 HC 的回读或三星显示。

消融实验在独立源码副本中一次删除一项保护，每次恢复后再执行下一项；不在用户工作区切换变体。基线使用同一组合成 fixtures。具体删除位置、命令、退出码和测试日志保存在本机实验目录，仓库仅维护脱敏结论。

| 消融项 | 原 review 测试能否检测 | 本轮正式测试结果 |
| --- | --- | --- |
| S1 去掉固定历史的首次初始化限制 | 能 | C28/C29 失败，检测成功 |
| S2 去掉已确认远端身份集合 | 能 | C05 与重组补偿断言失败，检测成功 |
| S3 去掉 attempted 持久标记 | 不能 | 未确认 A → 未发送 B → 源删除的补偿断言失败，检测成功 |
| S4 去掉发送前 UUID 可读性检查 | 不能 | 不可读时健康帧数与队列状态断言失败，检测成功 |
| A1 去掉旧版本阻挡 | 能 | 墓碑后旧 upsert 的断言失败，检测成功 |
| A2 忽略回读验证结果 | 不能 | 回读不符不得完成 journal 的断言失败，检测成功 |
| A3 去掉可信历史匹配检查 | 不能 | 新 planId + 错误起点不得被接受的断言失败，检测成功 |

本轮两个未消融基线均通过，7/7 个变体全部由行为断言检测到，没有把编译错误或安装失败计为成功。原 review 的 4 个测试盲点已补齐；这只度量这 7 个指定机制，不代表全部代码路径、真实 HealthKit、Health Connect 或三星行为均已证明。

## 提交前审查修复记录

本轮保持原数据语义和协议版本，修复以下四项问题，并覆盖同类恢复路径：

| 问题 | 实现与回归证据 | 对应验收 |
| --- | --- | --- |
| 重复采用重建计划清空新账本、重置版本 | SyncStore 验证旧/新数据集及原范围；同一已采用计划幂等返回，UIKit 保留配对。SR 重启后重复采用、错误计划和无关旧数据集零清理。 | C26/C29/C35 |
| iOS 停止后立即重试共享旧任务连接 | 原任务退出前保留 busy；读源及传输边界传播取消。SR 控制查询挂起、停止、立即重试，再释放查询；取消后无连接，收束后手动重试成功。 | C20 |
| 超限或无效睡眠组阻断其他记录，拒绝后丢旧锚上下文 | Normalizer 检查样本 UUID 上限。SyncStore 在 SQLite savepoint 内试算，拒绝后回滚，将拒绝依赖扩展到旧、新睡眠组件再重算；协调器保留 dirty/affected/deferred。错误按 UUID 清除。SR 验证独立组继续、首次不删除旧锚、重启仍受阻、修正后同组补偿、明确删除未导入的异常源后清错。 | C18/C21/C31/C32/C33 |
| Android 网络重启撤销用户停止 | 等待旧 Job 的重启和网络回调均绑定所属代次；检查和启动/停止同步执行。PT 控制恢复调用挂起，分别验证等待中停止、晚到旧回调不能重启，以及未停止时真正恢复监听。 | C20/C25 |

红/绿测试在独立源码副本执行，Android 仅将 applicationId 改为 `.ablation`，保留设备中既有签名安装。Swift 新增 7 项正式测试：初始 4 项在未修复逻辑上全部失败；随后组级拒绝隔离、旧锚上下文和异常源删除清错各有 1 项红测试。Android 新增 3 项：排队重启与晚到回调分别先观察到断言失败，正常重启是正向对照。最终通过数量见上方测试证据索引；未将编译或安装失败计作缺陷检测成功。

独立审查还用合法的 30 条分拆会话和 999 条重复睡眠证据复现了完整修订组超出帧大小后的跨轮错误消失。该探针用于补充问题定位；修复后该探针两轮都保留 1,029 个受阻 UUID 与 30 条旧会话，删除冗余证据后错误解除且不产生重复修订。正式协调器回归以小型无效源字段触发同一拒绝与回滚路径，避免将耗时压力输入加入每次测试。

同类扫描覆盖重建采用入口、两个 reconcile 调用点、iOS 分页/UUID 复读/连接/发送/完成及重试的取消边界、Android 显式启动、排队重启、地址变化和网络丢失回调。合法恢复时，分区也使用旧、新睡眠候选组件关系，旧锚删除与替代会话写入保持同一修订组。安全、架构及四类对抗复核仅针对这些修复差异，不替代完整真机验收。

命令沿用上方原生入口。此次红/绿日志和隔离源码位于本机 `/tmp/health-relay-merge-fix/`，包括 `swift-*-red.log`、`swift-final-verified.log`、`android-red.log`、`android-callback-red.log`、`android-final-verified.log`；临时日志不入库且不保证长期保留。正常仪器入口仍跳过 3 项真实 HC 测试，本轮未重跑可选 HC 聚合入口，也未验证三星显示。

## 平台差异与修复依据

1. Android 14 旧 HC 组件对授权前 30 天之前的自身记录回读失败，近期读写正常。API 36 / HC 360527520 已通过同一历史测试。官方 [读取说明](https://developer.android.com/health-and-fitness/health-connect/read-data) 声明 Android 14+ 自身记录不受该历史限制，但 [Android 14 AOSP 实现](https://android.googlesource.com/platform/packages/modules/HealthFitness/+/refs/heads/android14-release/service/java/com/android/server/healthconnect/HealthConnectServiceImpl.java) 的读取分支仍将查询下界提升到 permission access start。该旧组件不能据当前测试判定满足 C29；没有增加用户版本 READ_HISTORY、缩短 historyStart 或绕过回读确认。S24+ 首测必须记录系统组件版本，优先验证历史读回。
2. 可选聚合测试初用 shell grant，API 36 聚合返回 null；改为系统权限 UI 后所有 C30 场景通过。测试需英文隔离系统，不在用户真实健康数据环境自动点授权。
3. Android Keystore 使用 Conscrypt TLS 1.3 ECDSA 时需要支持预散列签名，配置增加 [DIGEST_NONE](https://developer.android.com/reference/android/security/keystore/KeyProperties#DIGEST_NONE) 后真实 TLS 测试通过；私钥仍仅在 Keystore。
4. iOS 标准 SSL 策略拒绝十年私有 leaf（`OtherTrustValidityPeriod`）。实现按已扫描指纹固定唯一叶证书，采用 [Basic X.509 策略](https://developer.apple.com/documentation/security/secpolicycreatebasicx509()) 校验签名/有效期，另严格检查 P-256 与 KU/EKU TLS 用途。正确十年证书、错指纹、过期、client-only 用途均有测试。没有全局 trust-all 或安装系统根证书。
5. 协议未知 offset 保留 null；[HC 数据格式说明](https://developer.android.com/health-and-fitness/health-connect/data-format) 规定 Android 14+ 插入后可采用设备默认 offset。因此回读严格比较已知 offset，未知 offset 不伪造历史时区，目标日期归属保留真机检查。

## 真机验收

当前全部 **待验收 / 受阻**。请先连接并解锁 iPhone 17 与 S24+，信任 Mac、允许 USB 调试；在 Xcode 选择个人 Team。应用安装和系统健康权限需设备本机批准。真实健康值与截图只在用户设备上查看，本表只填脱敏结果。

| 检查面 | 当前结果 | 完成时应记录 |
| --- | --- | --- |
| 版本与身份 | 无真机连接；iOS 无有效签名身份 | OS、应用、HC、Samsung Health 版本，地区/语言，profile 到期日；不登记设备序列号 |
| 正式扫描、双端确认、TLS 传输 | 待验收 | 3 组真实睡眠、3 条运动的传输计数与错误码 |
| HC 写入与回读 | 待 S24+ 验收，模拟器已通过 | session/阶段/距离/活动能量条数与误差；原历史范围回读 |
| 三星睡眠会话 / 阶段 / 时长 | 三项均待验收 | 分项通过/失败；拆分会话数、未知时长是否误计 |
| 三星运动会话 / 类型 / 距离 | 三项均待验收 | 至少两种运动；有距离样本的显示误差 |
| 活动能量与暂停时长 | 待验收 | HC 活动能量正确；三星热量字段语义与暂停消费限制 |
| 重复同步、更新及删除传播 | 待验收 | 连同步 3 次计数不变；修改/删除前后脱敏数量；三星副本是否残留 |
| 保留其他来源、历史重建 | 待验收 | 三星/Galaxy Watch 自有记录不变；原范围不缩短 |
| Wi-Fi、后台/锁屏、断网重试 | 待验收 | 恢复后无重复，待确认状态收敛 |
| 局域网可通但路由器外网断开 | 待验收 | 源读/传输/HC 与三星更新分别记录；三星自身云依赖单列 |

每次三星观察窗口为 5 分钟，按 [spec §11.2](specs/spec.md#112-s24-端到端验收发布阻断条件) 执行。窗口内核心会话不可见、阶段缺失、距离不关联或未知时长被计入时，记录本次失败并按官方权限设置排错；仍失败则停止宣称交付完成，向用户提交有证据的方案调整。不会自动切换到 Samsung partner SDK。
