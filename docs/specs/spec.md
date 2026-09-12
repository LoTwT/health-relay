# health-relay 个人健康记录同步规格

版本：v1.3

官方资料核对日期：2026-09-12（Asia/Shanghai）

状态：双端原生应用、协议、fixtures、可靠性机制和配套文档已实现；消融及提交前 review 发现的恢复缺陷已修复，模拟器构建、回归及消融证据见 [验收记录](../acceptance.md)。iPhone 签名安装及 S24+ 三星健康核心真机验收受阻，完整 MVP 尚未验收通过。

本文中的“必须”是本期实现和验收要求，“不承诺”是平台能力边界。文中的数字、JSON 和测试记录均为合成示例，不代表用户的真实健康数据。本规格是需求权威来源；Git 操作与对外发布以用户在 session 中的明确授权为准。

## 1. 推荐方案与完成条件

开发两个小型原生应用：iPhone 读取已经进入 Apple Health 的 HealthKit 睡眠样本和 HKWorkout；通过同一 Wi-Fi 的加密局域网连接发送；Galaxy S24+ 将其写入 Health Connect；三星健康在获得读取权限后消费这些记录。

第一版采用 Swift / UIKit 和 Kotlin / Jetpack Compose，支持一个人、一台 iPhone、一个 Android 接收端、每类数据一个明确选定的来源。两端保持前台和解锁，三星端手动进入接收状态，iPhone 手动点击同步。无自建云服务、账号系统、订阅、watchOS 应用或后台调度。

最小可用方案就是上述双端应用和一次手动同步。文件导出再搬运会增加日常步骤，且不能省去 Android 写入端；跨平台 UI 框架仍需维护两套健康 API 和签名集成，因此本期均不采用。iOS 快捷指令对普通健康样本的查询能力，不作为完整导出 HKWorkout、关联统计、事件和稳定标识的依据。

关键决策如下：

| 决策 | 选择与原因 |
| --- | --- |
| 写入三星生态的入口 | Health Connect；Samsung 官方确认支持运动会话、距离、睡眠会话和阶段等数据交换，但具体范围随三星健康版本变化。[Samsung 数据范围][S2] |
| iOS 安装 | 首选免费 Apple Personal Team + Xcode，接受每 7 天重新构建安装的维护成本；付费会员为可选项。[能力表][A1]、[账号限制][A9] |
| 历史范围 | 首次同步前 30 × 24 小时；符合第 6 节规则的会话完整导入，不在历史起点裁剪跨界会话。此起点固定保存，清除重建和更换来源也沿用它；只有真正首次使用才取当前时点减 30 天。 |
| 去重与修订 | HealthKit UUID、确定的睡眠会话标识、持久化版本和 Health Connect `clientRecordId`；重试重放相同操作。 |
| 睡眠时长 | 只导入阶段连续覆盖、至少含一段明确睡眠证据的会话；空档和无法确定的区间作为拆分边界，不写入会话总区间。 |
| 删除覆盖 | 传播实际收到的源删除事件；HealthKit 会定期清理这些事件，手动同步不保证补齐全部历史删除。不可读记录保留并提示核对，不据缺失自动删除。[删除事件保留][A23] |
| 能量 | Apple 的活动能量写入 `ActiveCaloriesBurnedRecord`；不冒充总能量。三星官方运动热量接口表使用 `TotalCaloriesBurnedRecord`，所以三星运动详情中的热量可能为空。[Apple 活动能量][A6]、[Samsung 映射][S2] |
| 成功定义 | “已写入 Health Connect”与“已在三星健康实际显示”分开。必须在用户 S24+ 上完成后者，才能判定项目达到目标。 |

**最脆弱的前提**：用户当前 S24+ 上的三星健康会读取并显示本应用写入的睡眠和运动。官方文档支持这条路径，但不能证明该设备、地区和版本上的最终界面行为。若会话本身无法显示，本方案没有达到目标；不得以 Health Connect 成功回执代替验收，也不得自动改成 Samsung Health Data SDK 或要求用户长期打开三星开发者模式。

## 2. 目标、范围与非目标

### 2.1 目标

1. 把 Apple Watch 已同步到 iPhone Apple Health 的主要睡眠和运动，单向导入 S24+ 的健康生态。
2. 首次完成安装、授权和配对后，日常操作保持为“两端打开应用 → 三星接收 → iPhone 同步 → 查看结果 → 查看三星健康”。
3. 网络中断后可重试，重复同步不新增重复记录，能说明哪些记录或字段没有导入及原因。
4. 只修改或删除 health-relay 自己写入的 Health Connect 数据。

### 2.2 数据范围

| 对象 | 必需内容 | 可缺失内容 | 不在本期 |
| --- | --- | --- | --- |
| 睡眠 | 开始、结束、至少一段明确的睡眠证据 | core / deep / REM / awake 等阶段、历史时区、设备描述 | 睡眠评分、呼吸分析、睡眠建议 |
| 运动 | 源 UUID、运动类型（允许映射“其他”）、开始、结束、源运动时长 | 源记录已有的距离、活动能量、可用的暂停事件、时区、设备描述 | GPS 路线、连续心率、圈速、功率、配速、训练计划、运动分析 |

没有阶段的明确 `asleep` 样本仍是有效睡眠；只有 `inBed` 的样本不证明已经睡着，本期不创建睡眠会话。没有距离或能量的运动仍可导入。缺失值不填 0，不根据体重、步数、心率、时长或日常静息能量估算。

以下全部不做：双向同步、三星记录回写 Apple Health、日常步数、ECG、日常活动汇总、提醒、完全后台同步、实时同步、联网中继、多人、多接收端、通用健康数据平台和后续扩展框架。Galaxy Watch5 已在三星健康留下的记录属于其他来源，本应用不整理、不删除，也不保证能识别它们与 Apple 记录的语义重复。

导入记录与三星自有算法是不同能力：不承诺能量分数、睡眠评分、活动圆环、睡眠教练或原生监测提醒会因第三方记录而更新。

## 3. 用户流程与页面行为

### 3.1 首次使用

1. 在 Mac 上用 Xcode 安装 iOS 应用；在 S24+ 安装使用固定签名的 Android APK。安装和更新步骤见第 10 节。
2. iPhone 打开 health-relay，说明读取目的，申请睡眠、运动及选填统计的读取权限；等待 Apple Watch 数据先出现在 Apple Health。应用不负责催促 Watch → iPhone 的同步。
3. iPhone 展示实际可读的睡眠和运动来源，各选择一个。若只有一个可识别的 Apple Watch 来源，预选它；有多个时展示名称、设备描述、最近记录时间和样本数，由用户在首次设置中选择。不得凭来源名称硬编码某个 Apple bundle ID。
4. S24+ 打开 health-relay，检查 Health Connect 可用性并申请本期写入权限；按第 10.3 节为三星健康开启相应读取权限。
5. 三星端点击“开始接收”，首次显示配对二维码；iPhone 扫码，三星端确认一次连接。两端保存配对信息，二维码自动失效。
6. iPhone 显示“首次同步最近 30 天”和选定来源，点击“同步”。两端显示处理进度与逐类汇总。
7. 提示“已写入 Health Connect，请到三星健康查看”。用户到三星健康的睡眠和运动历史查看，按验收表记录结果。

### 3.2 日常使用

1. 两台手机连接同一个可互通的 Wi-Fi，保持解锁。
2. S24+ 打开应用，点击“开始接收”。
3. iPhone 打开应用，显示已配对设备，点击“同步”。自动查找当前地址，不再次配对。
4. 查看新增、更新、删除、未变化、部分完成、跳过和待重试数量。可展开失败原因，不要求用户查看技术日志。
5. 打开三星健康查看目标日期；health-relay 结束接收，不常驻后台。

两端只需“同步/接收”和“设置/结果详情”两类页面。设置包含数据来源、配对、权限说明、故障诊断、“重新读取并核对历史”和“清除本应用导入并重建”。恢复时展示原历史起点、当前可读范围及清理影响。不添加分析仪表盘或提醒设置。

### 3.3 状态与措辞

| 状态 | 用户可见含义 |
| --- | --- |
| 等待接收 / 正在读取 / 正在传输 / 正在写入 | 显示阶段及已处理数量；不伪造预计完成时间。 |
| 已写入 Health Connect | 必需记录写入且按本应用来源回读核对成功；不表示三星健康已显示。 |
| 部分完成 | 会话已写入，但有可选字段未写入、修订未完成或独立记录失败。 |
| 没有可读取的新数据 | 不等同于“健康记录为空”或“读取已授权”。附入口说明可能与权限、来源选择、Apple Watch 同步延迟有关。 |
| 同步中断，可重试 | 保留成功进度；下次同步继续尚未完成的操作。 |
| 睡眠已拆分 | 某组源睡眠含空档或无法确定的阶段，已将有证据的连续部分导入为多条会话；显示导入条数及未导入的未知时长。 |
| 历史记录待核对 | 已跟踪的源记录当前不可读，原因可能是权限变化或删除事件已过期；保留已有目标记录，提供权限检查和历史核对入口。 |
| 需要重新配对 / 恢复设置 | 认证材料或同步数据库丢失；按第 8.6 节处理，不静默新建另一份历史。 |

“上次本轮同步完成”仅在本轮没有待重试项、结构错误或可用字段写入失败时更新；正常的源选填字段不可用可完成同步，但必须显示字段缺失说明。这个时间只说明本轮可处理变化已送达，不证明历史镜像一致。历史核对状态单独保存和显示，不随一次成功传输清除；结果详情固定说明“历史删除仅按实际收到的事件处理，可能存在遗漏”。另存“上次尝试时间”，不把失败覆盖成成功。

## 4. 架构与技术栈

```text
Apple Watch
    │ Apple 自带同步（本项目之外）
    ▼
iPhone / Apple Health / HealthKit
    │ 只读
    ▼
iOS health-relay
  HealthKitReader → Normalizer → SyncStore / Outbox → LAN Client
                                                        │
                                    同一 Wi-Fi，TLS 1.3，JSON 帧
                                                        ▼
Android health-relay
  LAN Receiver → Validator → ImportJournal → HealthConnectWriter
                                                        │
                                                        ▼
                                                  Health Connect
                                                        │ 三星健康的读取权限
                                                        ▼
                                                   Samsung Health
```

没有健康记录反向传输；Android 给 iPhone 返回认证、导入结果和恢复所需的数据集配置。三星健康自身与 Health Connect 或 Samsung 账号的同步由三星产品控制，不属于本项目协议。

| 层 | 明确选择 |
| --- | --- |
| iOS | Swift 6、UIKit、HealthKit；最低部署 iOS 26。使用支持用户设备系统的正式 Xcode；不依赖预览 SDK 才有的 HealthKit API。 |
| iOS 数据与网络 | 系统 SQLite、Codable、CryptoKit / Security、Keychain、Network.framework 的 `NWBrowser` / `NWConnection`；AVFoundation 扫二维码。 |
| Android UI | Kotlin、Jetpack Compose / Material 3、ViewModel / StateFlow；`minSdk=34`、`compileSdk=36`、`targetSdk=36`，覆盖 S24+ 的 Android 14 及后续兼容系统。[架构建议][G19] |
| Android 数据与协议 | Kotlin 协程、Room；JSON 编解码使用 `kotlinx.serialization`，线协议 DTO 与 Room 实体、Health Connect 记录分开。[序列化][K1] |
| Health Connect | 固定 `androidx.health.connect:connect-client:1.1.0`，核对日仍是稳定版；不照抄入门页的 alpha 依赖。[稳定版本][G1] |
| Android 网络与密钥 | `NsdManager`、平台 `SSLServerSocket`、Android Keystore；二维码编码使用 ZXing Core 单一库，不引入 Web 服务框架或内嵌浏览器。 |
| 协议与测试 | 仓库共享 JSON 契约和合成 fixtures；Swift XCTest、JUnit、Android 仪器测试。无共享业务运行时、无代码生成服务。 |

iOS 的所有界面统一使用 UIKit 实现，包括同步、配对、设置和结果详情。

Android 的业务页面使用单个 Activity 承载 Compose；Health Connect 所需的权限说明入口另按第 10.2 节声明。ViewModel 通过只读 StateFlow 暴露界面状态，Compose 使用 `collectAsStateWithLifecycle` 收集。接收操作交给独立协调器串行执行，界面重组或 Activity 重建不得重复创建监听或重放导入。依赖通过构造函数和应用级容器传入，初版保持一个 `app` 模块。[状态与依赖管理][G19]

首次实现时锁定兼容的正式 Kotlin、Compose、Room、KSP、序列化库、AGP 和 Gradle Wrapper 版本，使用 Gradle Kotlin DSL 和 `gradle/libs.versions.toml` 保存依赖选择。Compose 库通过稳定 BOM 对齐；Kotlin 2+ 的 Compose 编译插件与实际 Kotlin 编译器同版本，不能用 BOM 替代编译器兼容性检查。Room 使用 KSP 生成代码。选择支持 SDK 36 的正式 Android Studio 模板组合，不引入预览功能。[Compose 版本管理][G20]、[Room 配置][G21]

SDK 36 的工具链下限为 Android Studio Meerkat 2024.3.1 Patch 1 和 AGP 8.9.1；高于下限的版本仍须按官方矩阵选择兼容组合。Gradle 运行 JDK 的主版本随 AGP / Wrapper 一起锁定，同时满足插件要求与 Gradle 的 Java 兼容矩阵；Java 和 Kotlin 的 JVM 字节码目标统一为 17。SDK Build-Tools 按所选 AGP 的要求安装，不能仅凭已有 `platforms/android-36` 判定构建环境完整。SDK/JDK 的本机绝对路径只放环境变量或未入库的本地配置，仓库提交 Wrapper 及版本配置。[工具链兼容矩阵][G22]、[JDK 选择][G23]、[Gradle Java 兼容矩阵][G26]

IDE 与终端的 Gradle 构建使用同一个运行 JDK。启用 Daemon JVM criteria 时，将 `gradle/gradle-daemon-jvm.properties` 纳入版本管理；其选择优先于 `JAVA_HOME` 和 `org.gradle.java.home`。未启用时对齐 IDE 的 Gradle JDK 与终端的 `JAVA_HOME`，并检查本地 Gradle 配置是否覆盖它。工程创建后按第 12 节核对实际 JVM，不能仅凭 Android Studio 自带 JDK 或终端 `java -version` 判断构建兼容性。[Daemon JVM criteria][G27]

上述选择不要求改用 Flutter、React Native 或 Kotlin Multiplatform。空仓库没有既有语言或框架需要迁就。初版身份定为 iOS bundle ID `app.healthrelay.ios`、Android application ID `app.healthrelay.android`，初次签名配置完成后保持稳定；本文没有注册这些标识或执行 Git 提交。

模块职责必须集中：

- `HealthKitReader` 只负责权限请求、分页读取、UUID/删除事件和 workout 原有统计，不承担目标映射。
- `Normalizer` 负责来源筛选、睡眠整理、时间/单位规范化和运动类型映射，是可用 fixtures 测试的纯逻辑。
- `SyncStore` 以事务保存读取游标、最小源缓存、逻辑实体、版本、墓碑和待发送操作。
- `LAN Client / Receiver` 负责发现、配对、TLS、帧和回执，不直接改健康数据。
- `HealthConnectWriter` 负责四种记录的权限、元数据、幂等写入、回读和精确删除；`ImportJournal` 负责跨 Room 与 Health Connect 的崩溃恢复。
- UI 只驱动前台操作和解释结果，不推导或补造健康值。

实现机制另核对了两个现成项目：Google 官方 [HealthConnectSample 的 HealthConnectManager][R1] 将会话与距离等底层记录一起写入，并在操作前查询权限，本项目沿用这种职责分离；Stanford [SpeziHealthKit 的 QueryAnchor][R2] 用 secure coding 序列化 `HKQueryAnchor`，其 [查询实现][R3] 同时返回新增和删除，本项目采用这些机制持久化游标。不复制样例中的随机健康值、广泛时间范围删除、后台采集或 UI 框架，也不新增对 Spezi 的依赖。这些源码说明机制可落地，不证明三星健康的兼容性。

预计实现会超过 8 个文件，实际目标是两个应用和测试，不新增独立服务。工作量估计为熟悉两平台的工程师约 10-15 个工作日，包含集成与真机排错；这不是交付日期承诺。

## 5. 数据读取、来源和时间

### 5.1 来源策略

睡眠和运动各绑定一个 `HKSource.bundleIdentifier`；来源键是该字符串的 SHA-256。`sourceRevision.version`、操作系统版本和展示名称不参与来源身份，避免系统升级造成新来源。`HKDevice` 仅作为来源选择和归因信息，字段缺失时不拼凑序列号或推断设备型号。

仅处理所选来源的样本，不把 Apple Health 的全部来源相加；不假定第三方能完整复刻 Apple Health 的来源优先级或页面去重算法。同一 bundle 下的设备信息仍保留，但本期不建立多个来源自动择优规则。来源内部互相矛盾的样本按第 6 节显式处理。

睡眠的手机 `inBed` 来源不会为了“补齐”手表阶段自动并入。更换来源必须使用“更换来源并重建本应用导入”，按第 8.6 节保留原历史起点，展示新来源的可读范围和会清除的本应用记录数量后再执行；不得把新来源与旧来源直接叠加。正常 Xcode 覆盖安装不更换来源或数据集。

### 5.2 HealthKit 读取

读取 `HKCategoryType(.sleepAnalysis)` 和 `HKObjectType.workoutType()`。使用 `HKWorkout.statistics(for:)` 的关联统计；禁止把运动时间范围内所有健康数量样本相加，因为它们可能来自另一来源或另一场运动。[Workout 与关联统计][A4]

运动距离优先读取对应的 workout 关联统计：步行/跑步/徒步使用 `distanceWalkingRunning`，骑行使用 `distanceCycling`，游泳使用 `distanceSwimming`，轮椅使用 `distanceWheelchair`。只取 `sumQuantity()`；无适用或完整统计时，允许读取仍可用但已弃用的 `HKWorkout.totalDistance` 作为源已保存的汇总。多运动组合不自行叠加不同统计；仅使用其已有 `totalDistance`，否则缺失。[距离][A7]

活动能量优先取 workout 的 `activeEnergyBurned` 统计，兼容读取已有 `totalEnergyBurned`。后者虽名为 total，Apple 文档明确其含义是 **total active energy**，不能映射成 Health Connect 总消耗。[活动能量][A6]

HealthKit 的授权返回成功只表示授权流程结束；`authorizationStatus(for:)` 不能用来证明已获读取权限。空结果不触发源删除或全量清理。首次授权失败、设备健康数据不可用或读取报错时，分类说明并停止该类数据发送。[HealthKit 授权][A3]

当前 Apple 文档还包含 iOS 27 的有限历史授权 API；它不是本期 iOS 26 基线依赖。若运行系统只提供部分可读历史，仍只导入可读记录并显示实际覆盖范围，不宣称拥有完整历史。将来采用该 API 时必须使用其实际系统版本门槛，不能无条件调用。[有限历史 API][A15]

### 5.3 时间和单位

- 所有时间表示真实时间点；线上的格式统一为 UTC RFC 3339，固定毫秒精度，例如 `2026-09-10T14:30:00.000Z`。区间均为左闭右开 `[start,end)`。
- `start < end`；源 `durationMs` 必须大于 0，且不超过区间时长加 1 秒舍入容差。无效必需字段使整条记录跳过并报错，不能纠正成看似合理的值。
- 距离单位为米，活动能量单位为 kcal；只做单位换算，有限非负数才有效。源明确提供的 0 与缺失不同；不把缺失变成 0。源选填统计本身无效时将该字段标为 unavailable 并附字段错误，仍可导入合法的必需会话；网络 payload 若违反契约则由接收端拒绝，不在接收端静默改值。
- 优先使用 `HKMetadataKeyTimeZone` 中有效的 IANA 时区，分别计算开始和结束时点的 UTC offset；夏令时切换前后可以不同。[时区元数据][A8]
- 睡眠会话的开始/结束 offset 取覆盖相应边界的有效源时区；来源冲突或缺失则为 `null`。保存源时区描述便于诊断，但不将当前手机时区冒充历史时区。
- 写 Health Connect 的 `startZoneOffset` / `endZoneOffset` 时保留可用值，缺失则传 `null`，不默认写 UTC 或当前 S24+ 的 offset。此时目标如何归属日期由目标处理，旅行记录列为真机验证边界。
- 不按 UTC 日期、本地午夜或日历天拆开睡眠、运动；不重写结束时间来凑运动时长。

## 6. 睡眠规范化与映射

### 6.1 阶段表

Apple 将卧床和具体睡眠阶段表达为重叠样本；它们不是应相加的两份睡眠时长。Apple Watch 的 awake 样本通常只出现在睡眠样本之间，不能把两端没有阶段的数据推断为清醒。[Apple 睡眠模型][A2]

| HealthKit 值 | Health Connect `SleepSessionRecord` stage | 规则 |
| --- | --- | --- |
| `asleepUnspecified` / 旧 `asleep` | `STAGE_TYPE_SLEEPING` | 已入睡，具体阶段未知。 |
| `asleepCore` | `STAGE_TYPE_LIGHT` | 本期采用的近似标签映射；不主张两厂商分期算法相同。 |
| `asleepDeep` | `STAGE_TYPE_DEEP` | 保留区间。 |
| `asleepREM` | `STAGE_TYPE_REM` | 保留区间。 |
| `awake` | `STAGE_TYPE_AWAKE` | 不擅自升级为 `AWAKE_IN_BED` 或 `OUT_OF_BED`。 |
| `inBed` | 不单独写入 | 不计为睡眠，不生成第二条会话，不延长会话边界。 |
| 无法识别的新值 | 不把它当睡眠证据 | 记录 `UNSUPPORTED_SLEEP_VALUE`；没有其他明确证据覆盖的区间按第 6.2 节成为拆分边界，不写入目标会话。 |

目标常量和构造规则以 Jetpack 1.1.0 的 [SleepSessionRecord][G3] 为准。

### 6.2 形成会话的确定规则

1. 先筛选所选来源，按 UUID 消除重复输入，拒绝空区间或倒序区间。
2. 使用可识别的 asleep / core / deep / REM / awake 区间形成候选组；按开始时间、结束时间、UUID 排序。区间重叠或相邻间隔 **不超过 30 分钟** 时归入同一候选组；超过 30 分钟形成另一候选组。`inBed` 不连接两个组。候选组是重算和展示单位，不直接等于目标会话。
3. 候选组必须包含至少一个明确 asleep/stage 样本，否则跳过。候选边界取组内非 `inBed` 样本的最早开始和最晚结束。小睡与夜间睡眠使用同一规则。
4. 按所有边界切分为最小区间。一个细阶段或 awake 优先于笼统 asleep；多个相同细阶段视为一份。不同细睡眠阶段互相冲突但都证明已入睡时，降为 sleeping 并报 `CONFLICTING_SLEEP_STAGES`；awake 与细睡眠阶段冲突时，才在本地标为 unknown 并报同一告警。不能任意选择深睡或较新的 UUID，也不能把仅有分期争议误当成没有睡眠证据。
5. 在每段正长度的空档或 unknown 处拆开候选组，取其余 sleeping/light/deep/rem/awake 区间构成的最大连续部分；只保留包含明确睡眠证据的部分，每个部分形成一条目标会话。合并相邻同阶段，stages 必须从会话 start 连续覆盖至 end、互不重叠且无 unknown；只有 awake 的部分跳过。不得把未知区间改写为 awake、sleeping，也不向两端补阶段。拆分告警为 `SLEEP_SPLIT_FOR_UNCERTAINTY`，本应用详情展示源候选组被拆成几条及空档/冲突时长；缺失部分不能算作已导入。
6. 结束距本轮读取时间少于 30 分钟的候选组及其全部输出会话标记 `DEFERRED_OPEN_SLEEP`，下次处理；不提前制造“已结束的一晚”。延后规则使用源候选组结束时间，不依赖 S24+ 时钟。每次同步都重新评估延后队列，即使该轮没有新的 anchor 变化，也能导入现已封闭的会话。
7. 候选组超过 36 小时或合计超过 10,000 个规范化阶段时，整个候选组作为异常数据跳过，保留错误供查看，不通过拆分绕过限制。正常跨午夜睡眠不受影响。

Android 的睡眠总时长聚合从会话区间中扣除 awake/out-of-bed/awake-in-bed，不自动扣除空档或 unknown。[时长排除类型][R4]、[聚合阶段筛选][R5] 因此本期只写阶段连续且确定的会话。例如两段各 60 分钟睡眠之间没有 20 分钟的数据时，写两条各 60 分钟的会话，合计 120 分钟；若中间有真实的 20 分钟 awake 证据，则可写一条 140 分钟会话，其睡眠时长仍为 120 分钟。仅求明确 sleeping/light/deep/rem 区间之和属于源区间汇总，不推断缺失睡眠。构造前验证这个和等于会话长度减 awake 时长。

一晚可能在 Health Connect 和三星健康中显示为多条会话，不能承诺与 Apple Health 的页面分组相同。连续、无冲突的跨午夜睡眠仍是一条会话；三星若自行重新合并并把未知时间计入睡眠，须记录为时长展示验收失败，不把问题转成填造阶段。这是本期明确的整理规则。

### 6.3 稳定身份和重新分组

会话的 `anchorSampleUuid` 从实际为该输出会话贡献明确睡眠区间的源样本中选取，按贡献区间在该会话内的最早开始时间排序，并列取 UUID 字典序最小者。实体 ID 为 `hr1/<datasetId>/sleep/<sourceKey>/<anchorSampleUuid>/<startEpochMs>`，其中 `sourceKey` 是完整 SHA-256 小写十六进制，`startEpochMs` 是输出会话 start 的 Unix 毫秒整数十进制。这个后缀使同一源样本被冲突拆为两段时仍有不同 ID；不使用数组序号或本次导出时间。

补齐后半夜阶段、修改结束时间等未改变锚样本和会话 start 的情况，更新原实体并增加版本。若补入更早记录、锚样本删除、空档被补齐或冲突变化使会话合并/拆分，则对受影响旧、新 ID 集合做差分：不再存在的旧 ID 发 delete，保留或新增的 ID 发更高版本 upsert，同一实体在一组中只有一个 action。整个差分作为一个修订组，不能保留旧会话再叠加新会话。

只对缓存中实际受增加/删除影响的连通区间重新分组，向两侧扩展到超过 30 分钟的断点；不按“当天”或固定午夜窗口找邻居。修订组需包含所有受影响旧实体。相同源样本集重算必须得出相同 ID、阶段和边界。

## 7. 运动映射与信息损失

### 7.1 字段和子记录

| Apple 内容 | Android 写入内容 | 必需/约束 |
| --- | --- | --- |
| `HKWorkout.uuid` | 稳定实体 `hr1/<datasetId>/workout/<uuid>` | 必需；不使用导出时间或批次号作数据身份。 |
| `startDate` / `endDate` | `ExerciseSessionRecord.startTime/endTime` | 必需，保留原时间点。 |
| `workoutActivityType` | `exerciseType` | 必需，按下表；未知归其他。 |
| `duration` | 协议 `durationMs`；目标 notes 写“Apple Health 运动时长：…” | 必需。目标没有任意可写的独立 duration 字段。 |
| 完整暂停区间 | `ExerciseSegment` 的 `EXERCISE_SEGMENT_TYPE_PAUSE` | 可选，全部位于会话内。[暂停类型][G4] |
| 已有距离 | 同时间范围的 `DistanceRecord` | 可选，一场运动一条汇总记录。 |
| 已有活动能量 | 同时间范围的 `ActiveCaloriesBurnedRecord` | 可选，一场运动一条汇总记录。 |

三个可能的 Health Connect 子记录分别使用实体 ID 加 `:session`、`:distance`、`:active-energy` 的 `clientRecordId`，共享源实体版本和时间区间。距离和能量在 Health Connect 是独立记录，并无可由本应用设置的通用 session 外键；目标按时间、数据来源等关联它们。不得把距离或能量伪装成 `ExerciseSessionRecord` 内不存在的字段。[运动数据模型][G5]

相互重叠的两场源运动不凭时间自动合并，避免误删真实活动；标记 `OVERLAPPING_WORKOUTS`。此时三星健康对独立距离/能量记录的归属和汇总不保证准确，必须显示限制，不能将某一场统计复制到另一场。

### 7.2 运动类型表

下表右栏省略 `ExerciseSessionRecord.EXERCISE_TYPE_` 前缀。使用符号常量，不散布平台整数。原 Apple 类型始终保留在协议和目标 notes，三星界面能否显示 notes 另行验证。[Apple 类型][A5]、[Health Connect 类型][G2]

| Apple `HKWorkoutActivityType` | Health Connect 类型 |
| --- | --- |
| `walking` | `WALKING` |
| `running` | `RUNNING` |
| `cycling` | `BIKING` |
| `hiking` | `HIKING` |
| `swimming`，源 `HKMetadataKeySwimmingLocationType` 明确为 pool | `SWIMMING_POOL` |
| `swimming`，上述元数据明确为 openWater | `SWIMMING_OPEN_WATER` |
| `swimming`，场地未知 | `OTHER_WORKOUT`，notes 保留“游泳，场地未知” |
| `traditionalStrengthTraining`、`functionalStrengthTraining` | `STRENGTH_TRAINING` |
| `highIntensityIntervalTraining` | `HIGH_INTENSITY_INTERVAL_TRAINING` |
| `yoga`、`pilates` | 分别 `YOGA`、`PILATES` |
| `elliptical`、`rowing` | 分别 `ELLIPTICAL`、`ROWING` |
| `stairClimbing`、`stairs` | `STAIR_CLIMBING` |
| `flexibility` | `STRETCHING` |
| `dance`、`danceInspiredTraining`、`cardioDance`、`socialDance` | `DANCING` |
| `badminton`、`basketball`、`baseball`、`softball` | 分别 `BADMINTON`、`BASKETBALL`、`BASEBALL`、`SOFTBALL` |
| `soccer`、`americanFootball`、`australianFootball`、`rugby` | 分别 `SOCCER`、`FOOTBALL_AMERICAN`、`FOOTBALL_AUSTRALIAN`、`RUGBY` |
| `tennis`、`tableTennis`、`squash`、`racquetball` | 分别 `TENNIS`、`TABLE_TENNIS`、`SQUASH`、`RACQUETBALL` |
| `volleyball`、`handball`、`cricket`、`golf` | 分别 `VOLLEYBALL`、`HANDBALL`、`CRICKET`、`GOLF` |
| `boxing` | `BOXING` |
| `martialArts`、`kickboxing`、`taiChi`、`wrestling` | `MARTIAL_ARTS` |
| `climbing`、`fencing`、`gymnastics` | 分别 `ROCK_CLIMBING`、`FENCING`、`GYMNASTICS` |
| `paddleSports`、`sailing`、`surfingSports` | 分别 `PADDLING`、`SAILING`、`SURFING` |
| `crossCountrySkiing`、`downhillSkiing` | `SKIING` |
| `snowboarding`、`skatingSports` | 分别 `SNOWBOARDING`、`SKATING` |
| `waterPolo`、`underwaterDiving` | 分别 `WATER_POLO`、`SCUBA_DIVING` |
| `wheelchairWalkPace`、`wheelchairRunPace` | `WHEELCHAIR` |
| 所有未列出的类型、组合运动 `swimBikeRun`、未来未知值 | `OTHER_WORKOUT`，保留原名/原 rawValue；不拆成推算的分段运动 |

仅有 `HKMetadataKeyIndoorWorkout=true` 不足以证明使用跑步机、动感单车或划船机，因此本期不据此改成设备专用类型。室内/室外信息仅在源提供时保留。[室内元数据][A16] 游泳场地只使用 Apple 的 [swimming location 元数据][A22] 及其枚举，不从地点、运动名称或距离猜测。

### 7.3 运动时长与暂停

`HKWorkout.duration` 可能是扣除暂停后的时间，不一定等于 `endDate-startDate`。[Apple duration][A10] 按时间排序处理 `pause/resume` 和 `motionPaused/motionResumed`：分别维护手动与运动检测两条暂停状态，首次 pause 打开区间，对应 resume 关闭，同通道重复 pause 忽略；最后没有 resume 的已打开区间延至 workout 结束。合并两类区间的并集。`pauseOrResumeRequest` 仅是请求，不当作已经发生的状态变化。

只有事件序列无无法解释的 resume、区间合法，且“总区间减暂停并集”与源 duration 相差不超过 1 秒时，才写这些真实事件支持的 pause segments。没有完整事件或检查失败时，不创造一个虚构暂停去补差；保留真实开始、结束、源 duration，并提示 `DURATION_NOT_FULLY_REPRESENTABLE`。源 duration 在协议和本应用详情中必须精确保留，目标 notes 保留到秒。

因此三星健康显示的运动时长可能是完整区间，或受其对 pause segments 的支持影响。无暂停样本的时长一致是必验项；带暂停且源事件完整的行为须在 S24+ 单独确认。无法完整表达时，不能宣称三端时长完全相同。

### 7.4 能量与元数据

本期不写 `TotalCaloriesBurnedRecord`，不请求静息能量权限，不把活动能量加上按时长分摊的基础代谢量。若三星健康不消费 `ActiveCaloriesBurnedRecord`，仍在 Health Connect 正确保留活动能量，结果显示“活动能量已写入 Health Connect，三星运动热量可能不显示”。这个限制不会通过改名或填错字段来消除。

Health Connect 的 `DataOrigin` 由实际写入应用包名决定，必须显示为 health-relay，不冒用 Samsung Health 或 Apple 包名。设备 manufacturer/model/type 仅来自实际可用的源设备信息；可确定为 Apple Watch 才填 watch 与真实设备描述，不硬编码 Series 11 型号。手动输入标记取 `HKMetadataKeyWasUserEntered`；可确认的自动睡眠用 `Metadata.autoRecorded`，可确认的主动运动用 `activelyRecorded`，无法确定使用 `unknownRecordingMethod`。按真实采集方式归因，不因为本次点击“同步”就标为手工录入。[写入归因][G6]、[Metadata][G7]

## 8. 同步状态、幂等、修改和删除

### 8.1 固定历史起点与读取游标

真正首次使用时，在设置、配对前创建随机 `datasetId`；首次真正点击同步时保存 `historyStart = 首次同步时点 - 30 × 24h`。此后历史起点固定，重建、重装恢复和更换来源不能重新套用这个公式。iOS 保存起点与两类来源；Android 在首次已认证 `hello` 中持久化同一配置，之后同一 datasetId 的起点不一致返回 `HISTORY_RANGE_MISMATCH`，零写入。尚未选定的来源可为 null，该类不导入，首次选择后允许补齐；已选来源不能被普通 hello 改换或清空，冲突返回 `SOURCE_CONFIG_MISMATCH`，更换走重建流程。两类数据分别保存不透明的 `HKQueryAnchor`，不能把最新样本时间当游标，避免漏掉迟到、补录和同时间样本。[Anchored query][A11]

某类来源首次从 null 补齐时，该类以 nil anchor 从固定下界读取并建立所选来源缓存，不沿用此前在未选来源时得到的游标；另一类既有配置和同步状态保留。

睡眠查询固定下界为 `historyStart-48h`，用于保留跨起点会话的上下文；运动下界为 `historyStart`。查询采用与下界相交的样本条件，不用 strict-start 截断跨界记录，不设置会随每轮变化的上界或来源 predicate。最终仅导入结束时间不早于 `historyStart` 的完整实体；来源筛选在读取后进行。运行中的未来记录推迟到结束后处理。

每类查询设置 `limit=500`；完整处理回调返回的新增和删除列表，不自行截丢删除对象；循环推进页游标直到新增、删除都为空。每页将样本、所有已知且选定来源 UUID 的删除、受影响 outbox 的失效标记、待重算标记和新 anchor 在同一 SQLite 事务中落盘，不能以尚未导出为由保留已删除样本。同页同 UUID 既有新增又有明确删除时，删除优先。分页中断可从已持久化页继续；在该类页面尚未读完前不基于不完整睡眠缓存形成远端修订。另一类已完成读取的数据可以继续。

读取游标和远端送达状态必须分开：anchor 可在源变化安全落盘后前进，只有持久化回执才能结束相应发送项。因此一次坏记录不会阻挡之后的新记录，也不会因为提前推进游标而丢失失败项。

### 8.2 迟到统计和读取权限的歧义

HKWorkout 可以在创建后继续关联数量样本，仅依靠 workout anchor 不保证发现汇总变化。每次同步额外按 UUID 分页（每批 100 个）重新读取本数据集已跟踪且当前可见的 workouts 及其关联统计；比较规范化内容，只发送发生变化的字段/实体。这是个人规模下有意选择的简单重读，不引入每种数量类型的一套增量游标。[Workout 生命周期][A4]

选填字段使用 `value` / `unavailable` 两态：

- `value` 表示本轮源实际提供该值，可以写入或更新。
- `unavailable` 表示本轮无法取得，可能是源没有值或读取权限不可见。首次不写相应子记录；若此前已导入该字段，保留旧子记录并显示“本次无法重读，保留上次值”，不把它改成 0 或据此删除。

本期不自动传播“同一 workout 可选统计被清空但没有可确认语义”的情况；需要用户使用明确的清除并重建操作。新 UUID 取代旧 workout 时，旧 UUID 的明确删除仍按下一节删除其全部子记录。这是为避免权限撤销误删而接受的局限，不承诺精确镜像 Apple Health 的所有编辑方式。

首次发送或重试 upsert 前，都重新验证所依赖的源 UUID 当前可读；睡眠需验证该修订所引用的源样本。若已收到明确删除，执行第 8.4 节的取消与重算；仅仅无法重新读取时，暂停该关联修订组并标记 `SOURCE_RECORD_UNAVAILABLE`，不借旧缓存继续发送健康内容，也不把不可见解释成删除。明确的源删除墓碑不依赖重新读取已删除对象。设置提供“重新读取并核对历史”操作，供调整权限或怀疑历史遗漏后使用：对相应类型以 nil anchor 从固定下界分页重新读取、合并当前可见数据，保留实体 ID、版本和已导入数据。只有完整读取结束后才比较可见 UUID 集合；中断或权限错误不产生缺失结论。新获得权限的历史不依赖旧游标一定会返回新增，核对结果按第 8.7 节处理。

### 8.3 稳定 ID 与版本

`datasetId`、固定历史起点和来源设置持久保存；配对密钥更新不改变数据集。Health Connect 子记录 ID 按第 6、7 节形成，与地址、日期分组、传输批次、重新授权和重新签名无关。

每个新修订组从 iOS 持久化 `nextVersion` 分配正整数 Int64（从 1 开始、严格递增、同组使用同版本），并创建 UUID `changeSetId`。内容不变不增加版本。版本分配、逻辑实体变更、删除墓碑和 outbox 写入在同一事务完成；重试复用原组 ID、版本和内容。

Android 通过 `insertRecords` 配合 `Metadata.clientRecordId/clientRecordVersion` 完成 upsert；相同或较低版本不会覆盖高版本，版本由本应用递增，Health Connect 不代增。[Upsert 规则][G6]

Android 另存实体及各子记录的最新版本、成功/待处理状态和墓碑，用于阻止较旧的删除或 upsert 重放复活数据。相同组 ID 但不同内容，或同实体同版本却内容冲突，返回 `VERSION_CONFLICT`，不得静默覆盖。接收端以自己对解码对象的确定性编码计算内容摘要；协议不要求 Swift/Kotlin 生成相同 JSON 字节摘要。

### 8.4 修改和删除

| 情况 | 行为 |
| --- | --- |
| 同 UUID 内容变化 | 同实体 ID、更高版本，更新已有子记录。 |
| HealthKit 删除后重建为新 UUID | 旧 UUID 的删除与新 UUID 的新增；不以时间相近猜测二者身份。 |
| 收到已缓存、延后或待发送 UUID 的 `HKDeletedObject` | 无论是否导出，先移除选定来源的源缓存，取消依赖它的旧 upsert 并重算；workout 无剩余实体，睡眠按剩余样本重新形成会话。 |
| 收到已确认导出或可能已发出的 UUID 的 `HKDeletedObject` | 在本地处理之外，为可能存在的远端旧实体生成更高版本修订；workout 精确删除自己的 session/distance/active-energy，睡眠按旧、新实体集合差分删除和 upsert。 |
| 收到本数据集完全不认识或确定为非选定来源 UUID 的删除 | 忽略，不扩大删除范围；“未导出”本身不是忽略条件。 |
| 一次查询为空、读权限撤销、数据不再可见 | 不生成删除，不清空历史。 |
| Anchor 失效或反序列化失败 | 从固定下界重读并合并当前可见数据，已有 ID 可幂等更新；不从“重读未见”推导删除。提示历史删除可能遗漏，按第 8.7 节核对；需要重建时保留原历史起点。 |
| 用户在 Health Connect/三星健康删除或修改已导入数据 | 不反向写 Apple。普通无变化同步不强制恢复；更高源版本可能覆盖/重新创建。恢复操作按原历史范围重导当前可读且符合本规格的源记录，不承诺恢复源端已删除或无权读取的内容。 |

outbox 在首次尝试网络发送前持久化 `deliveryAttempted=true`。从未尝试发出的旧修订可以仅在本地标为 superseded；已经尝试发送的修订即使没有回执，也必须按远端可能已写入处理。删除只涉及睡眠的一部分时，取消整个旧修订组并重新计算完整差分，不能改写原 changeSetId 的内容或只丢弃其中一个 change。新版本同时覆盖曾经发送但未确认的旧实体，避免回执丢失后残留记录。

重算差分的旧集合包含最后已确认的远端状态，以及所有未确认但 deliveryAttempted 的修订可能产生的实体，不能只取最新本地规范化结果。从未发出的新身份被取消，也不能因此忘记更早已经导入的旧身份。

所有删除都用已登记的本应用 `clientRecordId` 或本应用写入返回的 record ID，按具体 record type 调用 `deleteRecords`；禁止清空日期范围内所有来源的数据。[删除 API][G8]

修订组在 Health Connect 中可能包含多个调用，Room 与 Health Connect 之间也没有共同事务。必须先持久化导入 journal，完整校验目标对象和所需权限，然后删除不再存在的旧子记录、upsert 当前子记录、回读核对，最后将完成状态和回执落盘。单次 `insertRecords` 内具有事务语义，但不能把“删除 + 插入 + 本地数据库”声称为一个原子事务。[事务边界][G9]

为避免修订时两份会话重叠，身份变化采用先删旧、后写新；中断可能暂时缺少本应用记录，journal 恢复后收敛。不得在失败时丢弃 journal。删除权限不足或必需会话无效时，整个关联修订组暂不开始；与它无关的运动/睡眠可继续。

### 8.5 分批、部分失败和恢复

- 一个修订组表示一场运动或一组必须一起重新分组的睡眠；网络批次最多 25 个修订组，且序列化帧不超过 1 MiB。单组超限报 `RECORD_TOO_LARGE`，不截断健康内容。只有操作上互不依赖的修订才能分组发送；同一睡眠修订的旧实体删除不能拆出单独提前执行。
- Android 每次只处理一个连接、串行处理修订组。网络批次只是传输单位；独立组分别返回结果，不能因一条坏记录取消整批已成功结果。
- 同一组的本轮可写子记录尽量一次 `insertRecords` 提交。距离/能量权限未授予时可先写必需会话和其他已获权字段，返回 `partial` 并记录缺少的子记录；下次只补写缺失部分。
- 已完成的会话不能在重试时创建新 ID。部分写入遇到更新版本时，新的完整源状态取代旧待处理版本，旧版本标为 `superseded`；旧队列随后到达只回报过期，不执行。
- Health Connect 成功后、journal 完成前崩溃：重试同 ID/版本并回读；不能凭本地没有回执就判断远端没写入。
- 回执丢失：iPhone 重发原修订组，Android 返回已完成结果或继续未完成的子步骤。iPhone 持久化回执后，才释放相应 outbox 内容。
- 连接或 IPC 短暂失败：本次前台操作最多延迟 1、2、4 秒各重试一次；随后显示可重试并结束，不永久后台循环。限流按服务给出的等待时间处理，无建议时保留队列到下次手动同步。
- 权限拒绝、协议不兼容、身份错误不自动反复请求。结构错误登记为失败并跳过该版本；后续内容/应用修复形成新版本可再试。所有非成功原因保留在结果详情，不把丢弃失败称为同步完成。

### 8.6 解绑、重装和清除重建

解绑默认仅撤销认证、停止连接，保留已导入健康记录与去重账本。三星端撤销 token 后立即拒绝旧设备；iPhone 单端“忘记设备”无法使离线三星端即时撤销其 token，界面应说明可以在三星端完成解绑。再次连接同一数据集时重新配对，不重新生成历史 ID。

“清除本应用导入并重建”按以下顺序执行，清理前先固定恢复范围，不能清理完成后才发现原起点丢失：

1. iPhone 恢复页读取原 `historyStart` 和来源；本地配置丢失时，通过用户确认的配对取得 Android 保存的恢复配置。两端都有配置但不一致时停止清理并提示核对，不选择较近的起点。两端均无可信起点时，不从剩余记录的最早日期冒充原起点，也不默认最近 30 天；用户必须明确选择重建起点及来源，界面说明原范围无法确认。此选择只用于恢复，不增加日常历史范围开关。
2. iPhone 按选定起点重新读取，展示当前可读条数、范围、已知不可读记录和原目标记录将被清理的影响。读取失败时不能进入清理；空结果不能证明源已清空，用户必须看到空结果及权限歧义。准备 `rebuildPlan={planId,oldDatasetId,newDatasetId,historyStart,sources}`，其中 planId/newDatasetId 为新 UUID；两端持久化相同计划。`prepareRebuild` 仅同步这份配置，不删除健康记录。尚未开始清理时取消恢复，保留旧数据集及队列。
3. Android 用户在本机确认清理，先停止普通接收、收束当前写入调用，再持久化计划的 clearing 状态。显示本应用四种记录的数量、来源、原起点和重建起点，明确仅重新导入当前可读源数据；不可读旧记录可能无法补回。按本应用类型和 ID 精确删除，失败时保留清理 journal、账本和计划，不恢复旧导入任务，也不接受新数据集。删除成功并回读确认后，撤销旧 token，将计划标为 cleared，保留配置和清理凭据，旧 datasetId 永久停用。缺少清理所需权限时停在恢复状态。
4. iPhone 在看到同一 planId 的 cleared 状态后选择“按原范围重建”，在同一 SQLite 事务中把 newDatasetId、原 `historyStart` 和确认的来源设为新配置，并清理旧 anchor、缓存、outbox 和版本状态，保留重建计划，再从原下界重新读取。重新配对后 Android 仅接受该计划的 newDatasetId 与相同起点/来源，将新配置绑定与返回 ready 的状态变更一起持久化，按正常权限检查和幂等写入重导。计划及清理凭据至少保留至新数据集首轮完成，响应丢失后仍可查询；进程退出后继续同一计划，不能重新生成起点或重复执行清理。恢复权限已改变时再次显示实际可读范围。

日常接收状态为 ready；准备计划不会授权清理，clearing/cleared 状态均拒绝旧数据集 applyBatch。cleared 状态允许恢复配对查询配置，以及计划中 newDatasetId 的重新配对，不能用旧 token 继续工作；新数据集首次 hello 成功绑定后才返回 ready。用户明确确认的“清理原目标并重建”不同于根据缺失自动推断源删除。恢复完成只表示原确认范围内当前可读、可规范化的源记录已重导，不保证无权限或源已删除的记录仍能恢复。三星健康可能保留已消费的副本，须按第 11 节实测，不能承诺清除 Health Connect 就回滚了所有三星界面。

任一端已知同步数据库丢失或损坏都进入 `RECOVERY_REQUIRED`；不靠 Keychain 恰好残留一个 token 就继续导入。Android 用自己包名的 `DataOrigin` 枚举所支持类型、过滤 `hr1/` ID，向用户展示清除重建范围。全新安装无法仅凭空数据库区分首次使用和卸载重装，因此每种类型在本安装首次写入前都须检查本应用已有 `hr1/` 记录；发现账本不认识的旧数据集即进入恢复，不创建并存副本。尚未获权的类型先不写，获权后补做这个检查。若一端配置仍完整，按该配置恢复原范围；两端都丢失则走上述明确选择起点的流程，不承诺自动找回原配置。仅 anchor 失效按第 8.4 节安全重读。不实现自动合并旧数据集或云备份恢复。正常保持 bundle ID、Team、Android 包名和签名的覆盖更新应保留状态，并纳入验收。

### 8.7 删除事件的保留边界与历史核对

HealthKit 用临时 `HKDeletedObject` 表示删除，并会定期清理；Apple 没有在所引文档中给出本应用可以依赖的固定保留天数。[删除事件保留][A23] 本期只在前台手动读取，不能保证长期未同步期间的所有删除都能补回，也不能用 anchor 可解码、查询为空或本轮发送成功证明删除历史完整。此限制始终显示在结果详情，不编造“多少天内绝对安全”的阈值。

正常同步传播实际收到的明确删除。重读或历史核对发现某个已跟踪 UUID 不可读且没有对应删除事件时，将它及依赖它的待发送修订标为待核对，保留已有 Health Connect 数据；可能是权限变化，也可能是已错过删除事件，不自动二选一。用户可先检查权限并执行“重新读取并核对历史”；记录重新可读或后来收到明确删除时，解除该项待核对状态。没有未决 UUID 仅表示这次可见性比较没有发现缺失，不升级为完整历史镜像保证。

核对后仍不可读时，保留记录是默认动作。若用户要以当前可读源记录重新建立目标数据集，必须使用第 8.6 节的原范围重建，在删除前查看不可读数量及可能无法恢复的影响；不自动清空、不静默缩短到 30 天，也不为弥补事件过期新增后台权限。独立且有效的新记录可以继续同步，历史核对提示单独保留。

## 9. 局域网协议、安全和本地存储

### 9.1 发现与配对

本期支持能互通的 IPv4 Wi-Fi 局域网，不支持 IPv6-only 网络、蜂窝直连、跨子网自动发现或访客 AP 隔离。Android 在“开始接收”后绑定 Wi-Fi 接口地址上的系统分配端口，使用 `NsdManager` 发布 `_healthrelay._tcp`；iOS 用 `NWBrowser` 浏览该固定服务。TXT 仅含协议版本和随机 receiver ID，不含健康内容、用户姓名或认证 token。[NSD][G10]、[Apple 本地网络][A12]

Android 地址变化即撤销旧服务、重新绑定并发布。iPhone 每轮重新发现；发现 5 秒失败后可短暂尝试上次地址，然后提供输入接收端当前 IP 和端口的入口。手动地址仍走相同证书固定和认证协议，不是第二套同步流程。同 SSID 不保证网络互通，故障提示区分未接收、权限拒绝、地址不可达和可能的客户端隔离。

首次配对：

1. Android Keystore 生成 P-256 TLS 私钥和自签名证书，证书期限设为 10 年；此证书仅用于本地设备身份，与 APK 签名证书无关。私钥不导出。网络层使用系统 TLS 1.3。
2. Android 在配对页生成 256-bit 一次性随机 `pairingSecret` 和随机 `pairingId`，仅内存保存，5 分钟后失效；显示二维码，含 `protocol=1`、receiver ID、IP、端口、证书 DER 的 SHA-256 指纹、pairingId、pairingSecret。二维码离开该页面后失效。
3. iPhone 扫码后，先将 TLS 对端证书与扫码指纹匹配，再在该连接内提交 `pair` 请求。检查证书有效期及用途；只信任这一张已固定的证书，不启用全局 trust-all，不安装系统根证书。[Network 连接][A13]、[TLS 校验接口][A14]
4. Android 核对一次性 secret、当前前台状态与期限，显示申请设备名称供用户确认；一次确认后发行新的 256-bit `pairToken`、`pairId`，通过已建立的 TLS 返回。此时一次性 secret 作废。
5. iPhone 保存 receiver ID、证书指纹、pairId 和 pairToken；Android 保存对应数据集、配对模式与 token 的 SHA-256 值，恒定时间比较。一次只保留一个已配对发送端；替换时明确撤销旧 token。恢复模式只授权读取恢复配置和准备重建计划，不能直接导入健康记录。

二维码密钥不进入日志、剪贴板或分享入口。iPhone 相机只在扫码页工作，不保存画面。若用户拒绝相机权限，提示在系统设置恢复；不增加弱口令、6 位码或明文传输的降级路径。

### 9.2 日常连接与帧

TLS 固定证书校验通过后，发送端在每个新连接的首个 `hello` 消息中携带 pairId、pairToken、sender ID、receiver ID、mode、datasetId 和 protocolVersion。normal 模式还必须携带已持久化的 historyStart 与 sources；sources 的 sleep/workout 分别为选定 bundleIdentifier，尚未选定时为 null。Android 校验 token 模式、当前数据集、配置一致性及 ready 状态后才接受健康消息，payload 来源必须匹配该类已选来源。recovery 模式的 datasetId 在配置丢失时可为 null，historyStart/sources 不必提供，只允许查询恢复配置、prepareRebuild 和 unpair；不能用提供普通字段绕过恢复限制。设备名、IP 和 Bonjour 服务名均不作为认证依据。证书不符必须终止并提示重新配对，不静默更新指纹。

帧格式为 **4 字节无符号大端长度 + 该长度的 UTF-8 JSON**。长度必须在 1 至 1,048,576 字节；先校验长度再分配内存；准确累计读取，不能假定一次 socket read 就得到一帧。每个请求的顶层均为 `protocolVersion:1`、字符串 `type`、UUID `requestId`，其余消息专有字段也放顶层。响应为 `protocolVersion:1`、`type:"result"`、原 requestId、布尔 `ok`；成功携带 `result`，失败携带 `error:{code,retryable}`。一次连接只允许一个未完成请求。TCP/TLS 的消息边界由这个长度前缀定义，不使用 HTTP、WebSocket、压缩或自制加密。

| 消息 | 方向与字段 | 结果 |
| --- | --- | --- |
| `pair` | iOS → Android；pairingId、pairingSecret、senderId、senderName、mode（normal/recovery）、datasetId（recovery 时可为 null） | 仅配对窗口可用，确认后返回 pairId、pairToken、receiverId、mode、receiverState 和 recoveryInfo。 |
| `hello` | iOS → Android；认证字段、mode、`protocolVersion=1`；normal 必须带 historyStart/sources | 返回支持版本、当前写权限、receiverState 和 recoveryInfo。配置冲突、恢复模式或待恢复且清理未完成时拒绝健康写入。 |
| `prepareRebuild` | 已认证 iOS → Android；rebuildPlan（第 8.6 节） | 校验原配置及计划后持久化，返回同一计划和当前状态；不触发健康数据删除，必须由 Android 本机确认清理。 |
| `applyBatch` | iOS → Android；generationId、batchId、changeSets | 每组、每实体、每子记录返回持久化结果；无全局“所有批次原子成功”。 |
| `finish` | iOS → Android；generationId | 返回本轮已记录的汇总；不是删除旧数据或推进 HealthKit anchor 的指令。 |
| `unpair` | 已认证 iOS → Android | 撤销当前配对，保留健康数据和账本，返回后断开。 |

receiverState 限定为 ready、RECOVERY_REQUIRED、clearing、cleared。recoveryInfo 的字段为 datasetId、historyStart、sources、rebuildPlan、rebuildState，表示当前数据集或待恢复的配置；rebuildState 为 prepared/clearing/cleared，无计划时为 null。未知配置字段为 null，真正首次使用且无恢复信息时整个对象为 null。historyStart 为 UTC RFC 3339 毫秒时间点，正常同步不能传 null。恢复配置只在成功认证或用户确认配对后返回，不进入 Bonjour TXT 或日志。

prepareRebuild 必须匹配已知 oldDatasetId 与原 historyStart，newDatasetId 不得等于旧 ID 或已停用 ID；只有原起点确实未知时才接受恢复页明确选择的起点。同一 planId 重试必须得到同一配置，不同内容返回 VERSION_CONFLICT；clearing 开始后不能替换计划。尚未清理时可取消或重新准备，Android 真正清理前必须显示当前计划并再次核对来源、起点与记录数量。oldDatasetId 仅在两端均无法识别旧数据集且扫描未发现旧 ID 时允许为 null；不能用 null 绕过发现的旧记录。协议没有远程清空命令。

未认证请求只允许 `pair` 或 `hello`，5 次认证失败关闭本次接收窗口。连接/TLS 握手超时 5 秒、单个请求等待回执 60 秒。无连接等待 10 分钟自动结束接收；已连接按请求超时处理。应用进入后台、手机锁定或用户停止接收时，注销服务并关闭 socket。当前正在调用的 Health Connect 操作完成状态依赖 journal 在下一次恢复；不申请后台常驻、唤醒锁或通知权限。

Android 的阻塞 socket 操作运行在 `Dispatchers.IO`。停止接收时先阻止协调器启动新的 Health Connect 调用，再显式关闭监听 socket 和已接受的连接，使等待中的 accept/read 退出；不能只取消协程 Job 就认为连接已关闭。保留未完成 journal，下一次用户开始接收时先恢复。UI 订阅的启动和停止不直接触发导入。[关闭监听 socket][G24]

### 9.3 数据契约

`generationId` 标识本轮已冻结的源变化集合，`batchId` 标识一批传输；都不是健康记录主键。同组重试不更改内容。跨轮仍可重发旧组，但不得把已被高版本替代的旧内容重新应用。

每个 change set 包含 `changeSetId` 与 `changes`。每个 change 包含 `entityId`、正整数 `version`、`kind`（`sleep` / `workout`）、`action`（`upsert` / `delete`）；delete 不含健康 payload。upsert 的公共字段如下：

| 字段 | 类型/要求 |
| --- | --- |
| `start`、`end` | 必需，UTC RFC 3339 毫秒时间点。 |
| `startOffsetSeconds`、`endOffsetSeconds` | Int 或 null，范围 −64,800 至 +64,800；null 表示未知。 |
| `source` | 必需：bundleIdentifier、sourceKey；可选 name、deviceType、manufacturer、model、timeZone。缺失为 null。 |
| `recordingMethod` | `automatic` / `active` / `manual` / `unknown`，由源证据决定。 |
| `warnings` | 固定错误码数组，可为空；不包含任意可执行文本。 |
| sleep 专有 | anchorSampleUuid；`sampleUuids`（参与候选组规范化的源 UUID，排序、唯一，含锚样本）；`stages`（start、end、type，排序、首尾连续覆盖完整会话）。type 仅为 `sleeping/light/deep/rem/awake`，至少一段明确睡眠。 |
| workout 专有 | sourceUuid；appleActivityType（已知符号名，未知写 `unknown:<rawValue>`）；exerciseType（上表目标常量后缀）；durationMs；indoor（Bool/null）；pauses 数组。 |
| workout 选填统计 | `distance={state:"value",metres:Number}` 或 `{state:"unavailable"}`；`activeEnergy={state:"value",kcal:Number}` 或 `{state:"unavailable"}`。 |

空字符串不能代替 null。名称只用于显示并限制长度 120 字符；源 metadata 不整包透传。NaN、Infinity、未知 action/kind、非整数版本、重复实体变更、越界/重叠/存在空档的睡眠 stages、unknown 睡眠阶段及超限字段拒绝处理。`entityId` 必须属于当前已认证 datasetId 与声明 kind，且与 payload 的 sourceUuid/anchorSampleUuid/sourceKey 一致；睡眠 ID 的 startEpochMs 必须由 payload.start 精确换算，`sourceKey` 必须等于 bundleIdentifier 的 UTF-8 SHA-256。目标子记录 ID 由 Android 自行派生，发送端不能指定任意 Health Connect record ID。删除未登记但合法的数据集内 ID 时不调用 Health Connect 删除，只持久化该 ID 的版本墓碑并回报 unchanged，阻止稍后到达的较旧 upsert；不得扩大删除范围。新增但不认识的健康枚举在规范化端处理，不能在写入端默认为有数据。

Android 使用有类型的 DTO 编解码，`version` 使用 Kotlin Long 对应 Swift Int64，不经过浮点数中转。显式配置 nullable 字段的编码规则以遵守上述 null 约定；缺失必需字段和非法枚举不得通过默认值补齐。解码后仍执行协议字段、身份与区间校验，再映射为目标记录。Swift / Kotlin 的共享 fixtures 同时验证编码和解码，防止序列化库默认行为改变协议含义。

`applyBatch` 先解析请求信封，再逐组解码和校验 change set，保持 C21 的错误隔离；单个坏组不能让已经可识别的合法独立组随整批 DTO 解码失败。顶层 JSON 损坏、信封无效或无法安全关联回执时拒绝整批。

以下是一条完整的合成 workout payload；它放在 `applyBatch.changeSets[].changes[].payload`，不是可以单独发送的顶层帧：

```json
{
  "start": "2026-09-11T10:00:00.000Z",
  "end": "2026-09-11T10:50:00.000Z",
  "startOffsetSeconds": 28800,
  "endOffsetSeconds": 28800,
  "source": {
    "bundleIdentifier": "example.synthetic.watch",
    "sourceKey": "2d1f341b806800c00799373dd7295088940e492001d8a4eac4f43608cd6dd7c5",
    "name": "合成测试来源",
    "deviceType": "watch",
    "manufacturer": null,
    "model": null,
    "timeZone": "Asia/Shanghai"
  },
  "recordingMethod": "active",
  "warnings": [],
  "sourceUuid": "6b5e22ae-443f-4f36-8b78-a8bd80e377da",
  "appleActivityType": "running",
  "exerciseType": "RUNNING",
  "durationMs": 2700000,
  "indoor": false,
  "pauses": [
    {
      "start": "2026-09-11T10:20:00.000Z",
      "end": "2026-09-11T10:25:00.000Z"
    }
  ],
  "distance": { "state": "value", "metres": 5000.0 },
  "activeEnergy": { "state": "value", "kcal": 325.5 }
}
```

批次回执的 `result` 含 generationId、batchId、`changeSets` 数组；每组返回 changeSetId 和 `entities`。每个实体必须返回 `entityId`、`version`、`status`，以及 `session/distance/active-energy` 各子项的完成状态或错误码（睡眠只使用 session）。状态限定为 `applied`、`unchanged`、`partial`、`retryable`、`rejected`、`superseded`；delete 成功返回 applied。`ok:true` 仅表示批次请求已处理，实体数组仍可能包含失败，发送端必须逐项检查。`applied` 必须建立在 Health Connect 成功和本地完成状态持久化之后；`unchanged` 只能基于已核对版本/内容及已完成 journal。不得用网络收到或 JSON 校验通过充当写入成功。

用户汇总以实际导入的睡眠会话/运动条数为主，另列选填字段；例如一场运动和两个统计子记录只算一场运动。睡眠拆分时附“1 组源睡眠导入为 N 条会话”，不把 N 条称为 N 晚；同组已知睡眠时长按输出的明确睡眠区间求和。状态恢复或旧回执重放不再次增加“本次新增”。

### 9.4 本地持久化与隐私

| 位置 | 保存内容与保留规则 |
| --- | --- |
| iOS Keychain | 配对 token、对端固定指纹、设备身份；`WhenUnlockedThisDeviceOnly`。 |
| iOS SQLite | 固定起点、来源、两个 anchor、已选来源的最小睡眠缓存、workout 汇总、实体/样本映射、历史待核对状态、版本、墓碑、outbox 及 deliveryAttempted、rebuildPlan；用完整文件保护，数据库和 WAL 均排除备份。 |
| Android Keystore | TLS 私钥；Android 进程不导出私钥。[Keystore][G11] |
| Android Room | 配对 token 摘要及模式、datasetId、固定历史起点与来源副本、停用的 datasetId、实体/子记录 ID 与版本、墓碑、待完成导入 journal、rebuildPlan/清理状态、结果汇总。成功 journal 的完整健康 payload 立即清除，仅保留去重和恢复配置所需信息。 |
| 日志 | 只存错误码、类别、计数、耗时、应用/平台版本；最多 7 天或 200 条操作摘要。禁止健康值、健康时间区间、源 UUID、token、二维码、完整 payload 和证书私钥进入日志。 |

源缓存是恢复增量语义所需，不是另建健康分析库。iOS 只保留固定起点及睡眠上下文之后的最小已选数据，不缓存连续数量序列；未选来源读取后立即丢弃。墓碑和版本随本数据集保留，只有完整清除重建才删除，防止旧重试复活记录。

两端不接入分析、广告或崩溃上传 SDK；Android 禁用应用备份和数据迁移中的上述数据；不使用 iCloud、外部存储或共享目录保存健康缓存。初次安装、下载工具、签名续期可能需要互联网；一次已配对的同步不请求互联网服务。三星健康是否另行同步 Samsung 账号，由用户的三星设置决定。

文件搬运不作为本期主流程或自动降级：Bonjour 被阻挡时先使用相同 TLS 协议的手动地址；客户端隔离则换可互通网络。只有真机确认用户网络无法满足此前提，才另行修改规格引入加密文件路径。本期不导出明文 XML/CSV/JSON 健康文件。

## 10. 权限、安装、资格和费用

### 10.1 iOS

应用启用基础 `com.apple.developer.healthkit` capability，申请 **只读**：sleepAnalysis、workout、activeEnergyBurned、distanceWalkingRunning、distanceCycling、distanceSwimming、distanceWheelchair。`toShare` 为空，不写 Apple Health，不启用 Clinical Health Records、后台 HealthKit delivery 或 HealthKit Estimate Recalibration。[HealthKit 设置][A17]

`NSHealthShareUsageDescription` 必须说明“读取睡眠、运动及已有距离和活动能量，仅在你点击同步时发送到已配对的三星手机”。因本期没有写入请求，不索取健康写权限，也不以虚假写入用途应付配置。

另声明：

- `NSLocalNetworkUsageDescription`：发现并向已配对手机发送健康记录。
- `NSBonjourServices`：仅 `_healthrelay._tcp`。
- `NSCameraUsageDescription`：扫描接收手机显示的一次性配对码。

使用固定服务类型的系统 Bonjour，不自己发送 UDP 广播或任意服务扫描，不引入受额外限制的 multicast entitlement。两端前台使本期无需后台权限。[本地网络规则][A12]

免费 Personal Team 的能力表中，HealthKit 在免费 Apple Developer 栏也被标记支持；本规格核对了网页原始表格的图标，而非把文本提取后空白单元格视为不支持。基础 HealthKit 的免费自用开发可行，不等于所有 Apple 健康 capability 都免费开放。[能力表][A1]

开发安装使用用户自己的 Apple Account 在 Xcode 登录，添加 Personal Team，保持固定 bundle ID，连接 iPhone、信任 Mac，并在系统要求时开启 iOS Developer Mode。免费签名的 provisioning profile 自签发起 **7 天失效**，届时需要在 Mac 用 Xcode 重新构建和覆盖安装；保持原 app 数据，不先卸载。免费账号还受 App ID、设备和安装应用数限制，官方当前为 10 个 App ID、3 台设备、每设备 3 个应用等限制。[Personal Team][A9]

Apple Developer Program 为可选的 **99 USD/会员年，地区价格以结算为准**，提供 TestFlight、App Store 和其他分发能力；不是基础 HealthKit 的必购许可。付费开发/Ad Hoc 构建仍受证书和 provisioning profile 到期约束，不能写成永久安装；具体截止日看实际 profile。TestFlight 的构建最长测试 90 天，仍需更新构建。[会员][A18]、[TestFlight][A19]

### 10.2 Android

S24+ 使用 Android 14+ 的系统 Health Connect；启动和每次接收前检查 `getSdkStatus`，不可用时提示更新系统组件。是否有可用组件以设备检测为准，不因型号直接认定可用，尤其要记录地区/系统版本差异。[入门][G12]

必须声明并按需请求：

| Health Connect 权限 | 作用 | 拒绝时 |
| --- | --- | --- |
| `android.permission.health.WRITE_SLEEP` | 写入/管理本应用睡眠 | 暂停睡眠，其他类别继续。 |
| `android.permission.health.WRITE_EXERCISE` | 写入/管理本应用运动会话 | 暂停运动及其子统计。 |
| `android.permission.health.WRITE_DISTANCE` | 写入源运动距离 | 会话可导入；显示距离未导入。 |
| `android.permission.health.WRITE_ACTIVE_CALORIES_BURNED` | 写入源活动能量 | 会话可导入；显示活动能量未导入。 |

写权限允许读取本应用自己写入的数据，用于回读校验与修复；始终设置本应用包名的 `DataOrigin` 过滤，不申请其他应用记录的 READ 权限。Android 14+ 回读自己的历史没有一般第三方读取的 30 天限制，因此不为本期申请 `READ_HEALTH_DATA_HISTORY`。这里的 30 天默认导入范围是产品选择，不是写入 API 的硬限制。[自有数据读取权限][G13]、[历史读取][G14]

提供 Health Connect 权限说明 Activity 和 Android 14+ `VIEW_PERMISSION_USAGE` / `HEALTH_PERMISSIONS` 入口，满足用户从系统权限页查看用途的要求。每组写入前重新检查权限，处理操作中撤销产生的 `SecurityException`。[配置要求][G12]

网络基础权限为 `INTERNET`、`ACCESS_NETWORK_STATE`。应用不读取 SSID、不做 Wi-Fi 扫描，因此本期不申请位置权限。Android 14+ 前台 `NsdManager` 由系统管理 multicast reception，本期不持有 Wifi MulticastLock。[NSD][G10]

核对日 Android 17 文档新增了 target 37 的 `ACCESS_LOCAL_NETWORK` 运行时权限。本期明确使用稳定 SDK 36 基线；如果实现时为了用户系统提升到 target 37，必须同时补齐这个权限和拒绝路径，不能只改 targetSdk 继续宣称 INTERNET 足够。SDK 37 文档仍包含 Preview 安装说明，不将它作为本项目初版必需工具链。[Android 17 网络权限][G15]、[SDK 37 设置][G16]

个人开发用 Android Studio/ADB 安装，无需为本期注册 Play Console 或申请 Samsung 合作伙伴。长期自用 APK 使用固定包名与妥善保管的自签名 release key，更新时不更换签名；调试的 USB debugging 属安装开发设置，不是三星健康数据访问资格。若通过文件安装 APK，需要为实际安装来源开启“允许安装未知应用”，这不是健康读取授权。

### 10.3 三星健康配置与核验

1. 更新三星健康至该设备/地区可获得的稳定版本。Samsung 文档列出的 Health Connect 集成起点为 6.22.5，但此旧版本号不是本项目推荐安装版本。[FAQ][S1]
2. 打开三星健康 → 设置 → Health Connect → 应用权限 → Samsung Health；首次可能需要点“开始使用”。若系统菜单名称变化，可从 S24+ 设置搜索 Health Connect 进入。
3. 给 Samsung Health 开启 **读取睡眠、运动和距离** 的权限；若该版本列出活动能量的读取选项，也开启它。只开启“写入”不能让三星读取 health-relay 数据。三星现有写入权限可由用户保持，不是本项目的导入前提。
4. 若在 Android 系统设置中授权，授权后启动一次三星健康；打开目标日期的睡眠和运动历史，必要时按其现有刷新方式刷新。
5. 看不到记录时，先确认 Health Connect 内记录存在、来源为 health-relay、时间正确，再检查 Samsung Health 的读取权限、版本和展示日期。官方还给出 Samsung 账号同步/Sync now 的排错建议；这属于三星自身账号/云同步设置，不在后台替用户启用，也不能作为 health-relay 云端中继。[Samsung 配置和排错][S1]

三星没有向本应用提供“已在页面显示”的确认回调；不轮询三星私有数据库，不用无障碍抓取三星界面来制造成功标志。实际显示由真机验收确认。

### 10.4 普通授权、开发与公开分发的区别

| 场景 | 所需资格/成本 |
| --- | --- |
| 普通自用同步 | 两端应用权限、一次配对、Samsung Health 的 Health Connect 读取授权；无本应用账号、API key、服务费或订阅。 |
| iOS 自用开发安装 | Mac + Xcode + 免费 Apple Account；每 7 天维护签名。Mac/手机已有硬件不列为免费赠送资源。 |
| Android 自用开发安装 | Android Studio/ADB 或固定签名 APK；无需 Play 上架、Samsung partner 注册。 |
| 可选 Apple 公开分发 | 付费 Developer Program、签名与 App Store/TestFlight 流程，健康数据用途、隐私与审核要求；本期不发布。 |
| 可选 Google Play 公开分发 | Play Console 注册当前为 25 USD 一次性费用，并有账号核验、适用测试要求、Data safety 和 Health apps 声明及权限审核；费用不是 Health Connect 写 API 订阅。[Play 注册][G17]、[健康应用发布][G18] |
| Samsung Health Data SDK 直写 | 另一个方案，涉及注册应用包名/签名和可用数据范围；当前 developer mode 写入也要求获批的 partnership access code。开发者模式限测试调试，不应作为用户使用指南。本期不接入。[Samsung Developer mode][S3] |

本期运行时不需要第三方 API 密钥、OAuth、Google 服务账号或 Samsung partner token。Apple Account 只供 Xcode 签名使用，密码不进入应用、规格或仓库。APK 签名私钥同样不能放进仓库。公开发布、其他地区分发的新要求不在本次执行范围，不等同于用户已授权上架。

## 11. 验收标准

### 11.1 契约与自动化验证

实现必须提供合成 fixtures，覆盖下表；Swift 与 Kotlin 对同一契约得到一致字段和目标记录。用纯逻辑测试覆盖规范化，用真正的 Health Connect 仪器测试覆盖持久化和权限；仅 mock API 不能证明集成成立。

| 编号 | 场景 | 可检验的通过条件 |
| --- | --- | --- |
| C01 | 同一运动/睡眠连同步 3 次 | Health Connect 中本应用 session 和统计记录的 ID 集合及条数不增加；后两次报告未变化。 |
| C02 | 一次批次写入后丢失回执 | 重发相同修订组只返回/完成原结果，不创建新 ID；首次新增计数不重复。 |
| C03 | workout 迟到距离/能量统计 | 不改 workout UUID，也能在下次重读后更新对应子记录；不新增第二场运动。 |
| C04 | 收到源 workout 的明确删除事件 | session、distance、active-energy 全部精确删除；同日期三星/Galaxy Watch 原记录不变。事件过期未收到的情况另按 C34 验证。 |
| C05 | 睡眠锚样本删除、两晚合并/拆分 | 修订后只剩计算出的目标会话；旧会话不残留，旧版本不能重放复活。 |
| C06 | 阶段连续、无冲突的 23:00 至次日 07:00 睡眠 | 一条完整 session，不按午夜拆分；开始/结束时间点准确，明确睡眠时长与扣除 awake 后的时长一致。 |
| C07 | inBed 与完整阶段重叠 | 不出现第二条 session，不双倍计时；边界取非 inBed 证据。 |
| C08 | 只有 asleep / 只有 inBed | 前者导入 SLEEPING；后者跳过且说明，不制造净睡眠。 |
| C09 | 重叠重复阶段与冲突细阶段 | 同阶段只保留一次；细睡眠阶段之间冲突降为 sleeping 并告警，awake 与细睡眠冲突仅在本地为 unknown 并拆分；每条输出 stages 连续、无 unknown、无重叠。 |
| C10 | 小睡、30 分钟/30 分 1 毫秒间隔、晚到阶段 | 严格按阈值形成候选组，真实空档仍拆成独立目标会话；补齐末尾且锚/start 不变时 ID 不变；未封闭候选组全部延后。 |
| C11 | 开始与结束 offset 不同的 DST/旅行记录 | 时间点不变，两端 offset 分别保留；未知 offset 仍为 null。 |
| C12 | 相同时间多个来源 | 只导入选定来源；不会把源数量合计；相邻 Galaxy Watch 记录不受管理。 |
| C13 | 含 5 分钟暂停、源时长 45 分钟、总区间 50 分钟 | 源时长保留 45 分钟，真实 pause 为 5 分钟；不把 endTime 改成 45 分钟。 |
| C14 | 时长有差但没有可解释暂停事件 | 不合成 pause；标记不能完整表达，源 duration 仍可查看。 |
| C15 | 缺距离/能量、值为 0、活动能量为 325.5 kcal | 缺失不写统计，0 保留为已提供值；325.5 仅写活动能量，不写总能量。 |
| C16 | 未知运动类型、室内跑步、游泳场地未知 | 未知和未知场地游泳归 OTHER；室内标记不擅自变成跑步机。 |
| C17 | iOS 读取拒绝/撤销返回空 | 不判定已授权，不生成全量删除，不重放不可重新读取的缓存 upsert；提示检查权限。 |
| C18 | Android WRITE_SLEEP 被撤销 | 睡眠报权限问题，合法运动仍可处理；重新授权后继续，无重复。 |
| C19 | 距离或能量写入权限缺失 | 会话可成功，字段状态为部分完成；恢复权限只补缺失子项。 |
| C20 | 收到半帧、Wi-Fi 断开、后台/锁屏、写入中进程终止、Android 界面重组/Activity 重建 | accept/read 阻塞时也能停止接收；重组/重建不增加监听或重复执行导入；不丢 outbox/journal，恢复后收敛；最多允许修订过程中暂时缺少本应用记录。 |
| C21 | 一个合法组和一个坏组同批 | 合法组成功；坏组有明确错误和保留状态，不谎称整批成功。 |
| C22 | 旧版本、重复组 ID 不同内容、旧删除重放 | 不覆盖新值、不复活已删记录；冲突有可见错误。 |
| C23 | 超长帧、非法数字/枚举、缺失必需字段、越界阶段、错误证书/token | 在健康数据写入前拒绝；Swift / Kotlin fixtures 保留 null 与合法 Int64 版本精度，溢出或非整数版本拒绝；错误证书不自动信任；认证前无健康内容交换。 |
| C24 | Bonjour 不通但 IP 可达 | 手动 IP 仍通过同一配对证书和 TLS 导入；不用明文文件。 |
| C25 | 对端 IP 改变、解绑、过期二维码 | 已配对设备可重新发现；旧 token/二维码拒绝，正常同步不重新配对。 |
| C26 | anchor 丢失、数据库丢失、免费签名覆盖更新 | anchor 重读不从缺失推删；数据库丢失要求恢复并保留另一端可信历史起点；正常覆盖更新保留来源/配对/ID。 |
| C27 | 清除重建 | 先在两端持久化计划，再由 Android 本机确认；只清除本应用支持类型与 ID；清理完成前新数据集零写入；不删除 Samsung 自有记录。 |
| C28 | 首次 30 天起点穿过一段连续睡眠、连续数日不打开、样本迟到 | 完整保留与起点相交且符合范围的输出会话；固定下界不随今天移动；当前实际读到的新增不因重试遗漏，已封闭的延后睡眠即使无新样本也能发送；不据此声称删除历史完整。 |
| C29 | 使用半年后清除重建或更换来源 | historyStart 与原起点完全一致，范围内早于本轮 30 天且当前可读的记录重新导入；已不可读记录明确提示，不能静默缩短范围。 |
| C30 | 两段各 60 分钟睡眠，中间空档为 20 分钟或 1 毫秒 | 输出两条会话，明确睡眠合计 120 分钟；Health Connect 仪器测试隔离本应用来源核对 SLEEP_DURATION_TOTAL 为 120 分钟。另测中间为真实 20 分钟 awake 时，一条 140 分钟会话的聚合睡眠仍为 120 分钟。 |
| C31 | 同一源 core UUID 被 awake 冲突拆成两部分，随后冲突消失 | unknown 部分不写入，两个输出 ID 因 startEpochMs 不同而唯一；重复重算 ID 不变；冲突消失后按集合差分更新并删除旧片段，无重复实体 action、无残留旧会话。 |
| C32 | 延后/从未发送的睡眠样本删除，及同页新增后删除 | 删除在推进 anchor 前移除本地样本、作废依赖的 outbox 并重算；下一次首次发送不含已删片段；不因已删 UUID 复读失败而永久卡住。 |
| C33 | 已尝试发出但无回执的样本删除，旧 upsert 晚于补偿删除到达 | 必须生成更高版本补偿修订；远端记录若存在则删除/重算，未登记 ID 也持久化墓碑；旧 upsert 到达不得复活已删片段。 |
| C34 | 模拟删除事件已清理、anchor 仍可用，历史核对发现 UUID 不可读 | 不自动删除目标或误报完整历史同步；保留待核对状态，独立记录可继续；恢复可读性或收到明确删除后解除对应状态，重建仍使用原范围。无需等待系统真实清理事件才能运行合成用例。 |
| C35 | 重建准备/部分清理/清理完成后崩溃，两端起点不一致或同时丢失 | 同一计划可恢复，旧 token/数据集不可重放；重复 prepareRebuild 不改变计划，recovery token 不能 applyBatch；起点不一致时零清理，两端都丢失时必须明确选择范围，不能默认最近 30 天。 |

### 11.2 S24+ 端到端验收：发布阻断条件

必须使用用户的 iPhone 17、Apple Watch Series 11 已进入 Apple Health 的真实记录，以及用户的 Galaxy S24+。当前实施仍未完成这一步，分项结果见 [真机验收记录](../acceptance.md#真机验收)。

1. 记录两端 OS、应用版本、S24+ 系统 Health Connect 组件版本、三星健康版本、地区/语言和权限设置；不把不同固件的演示视频作为本机证据。
2. 选取至少 3 组睡眠（含连续跨午夜、有阶段、可取得时的小睡）和 3 条运动（至少两种类型，一条有距离/活动能量，一条无选填统计），对照 Apple Health/本应用源预览、Health Connect 和三星健康的目标日期详情。另用明确标注的合成记录验证空档、冲突与 awake 对照场景；这些记录与真实验收数据分开登记，用完精确清除。
3. 三星健康 **必须可见睡眠会话和运动会话**，必需起止时间正确，常见运动类型正确；显示精度的正常分钟舍入可接受，真实时间点在 Health Connect 应精确到协议毫秒。连续睡眠为一条；拆分睡眠核对各部分的真实区间，不能把多条算作多晚。睡眠阶段在源有值、映射可表达时，应能在三星阶段详情看到对应信息；若只显示总区间，记录为阶段展示不通过，不能称全部范围已交付。睡眠总时长须与明确睡眠区间之和一致，未知/空档不得计入；三星自行合并导致多计时长同样判为展示失败。
4. 对有距离的运动，先验证 Health Connect 数值，三星运动详情距离与源换算值在其显示精度内一致才判定“距离在三星显示”通过。若 HC 正确但三星不关联，保留为明确兼容性失败，不将另一场的值补上去。
5. 活动能量在 Health Connect 必须正确。三星热量字段为空属于第 7.4 节已声明边界，不能宣称已同步三星运动热量；若界面显示数值，还须确认该值语义，不能仅因数字接近就认为是总消耗。
6. 带暂停的运动分别记录三星显示的时长和源时长。若目标不消费 pause/notes，报告具体损失；无暂停普通运动的时长不一致则验收失败。
7. 第一次成功后重复同步两次，三星健康的可见会话数量也不得增加；删除和修改后检查三星是否更新或移除已消费记录。HC 删除成功但三星副本残留必须单列失败/平台限制，不以自动批量删除三星自有数据补救。
8. 在正常 Wi-Fi 下保持前台，并打开/刷新三星健康，观察 5 分钟。这个时间是测试观察窗口，不是 Samsung 官方 SLA；窗口内未显示就记录为本次未通过，按官方设置排错后重测，不凭空解释为必然稍后出现。
9. 至少一次保持局域网连通但断开路由器外网，验证已安装、已配对应用能读取/传输/写入；分别记录三星界面能否同样更新。若三星需要其自身云同步，明确记录该外部依赖。
10. 真机证据只在用户设备上检查；默认不上传健康截图或原始数据。项目验收记录用脱敏计数、误差、错误码和版本信息。

Health Connect 的真实聚合验收放在仅含本应用合成数据的测试设备/配置中，申请测试所需 READ_SLEEP，使用明确 DataOrigin 和时间范围核对 C30/C31；测试权限不加入用户自用版本。用户版本仍只申请第 10.2 节的写权限，回读自身记录并求阶段时长进行核对。生产设备若已有其他来源重叠睡眠，不能把系统跨来源聚合结果当成本应用转换正确性的单独证据。

验收结论必须分别列出：传输通过、Health Connect 写入及睡眠时长通过、三星睡眠会话/阶段/时长通过、三星运动/距离通过、活动能量边界、暂停时长边界、实际删除传播结果及事件过期限制。核心会话不可见或导入造成未知睡眠时长增加时，本项目不能标记完成。

## 12. 实施顺序、文件归属与回退

本期作为 **一个完整 MVP 交付单元** 实现。以下是单元内的工作顺序，不是可以各自宣称产品可用的独立发布阶段，也不安排“以后再研究核心路径”的阶段。

| 顺序 | 实现目标与文件归属 | 完成检查 |
| --- | --- | --- |
| 1 | `ios/HealthRelay.xcodeproj`、iOS entitlement/Info.plist、`android/` 原生工程、固定应用身份、权限说明 | 两端能签名安装；读到实际 source/workout；S24+ Health Connect 能获权。记录 Personal Team profile 到期日。 |
| 2 | `protocol/` 数据契约和 `fixtures/` 合成输入；iOS `HealthKitReader`、`Normalizer` | 来源、睡眠、运动映射与异常 fixtures 通过；没有统计推算。 |
| 3 | 两端 LAN/Pairing 模块和 Android `HealthConnectWriter` | 经正式配对/TLS 完成少量真实睡眠及运动的完整链路，立即执行三星显示验收以暴露最关键兼容风险。 |
| 4 | iOS `SyncStore`/Outbox、Android Room `ImportJournal`，连接现有读写模块 | anchor、版本、精确删除、统计重读、睡眠拆分时长、断线和崩溃恢复通过 C01-C35。 |
| 5 | 两端结果与设置页、历史核对、原范围重建/解绑；`docs/setup.md`、脱敏 `docs/acceptance.md` | 日常流程无需开发工具；权限/费用/维护说明完整；S24+ 全部核心验收通过。 |

实施前检查 Android Studio / AGP 兼容性、SDK Platform 36 和所选 AGP 要求的 Build-Tools。SDK 管理使用 Android CLI，以 `android --version` 和 `android --sdk="$ANDROID_HOME" sdk list` 分别检查工具版本和已安装组件；用 `adb version`、`adb devices -l` 检查 ADB 与设备连接，使用模拟器时再执行 `android --sdk="$ANDROID_HOME" emulator list`。`ANDROID_HOME` 指向 SDK，终端 PATH 包含其 `cmdline-tools/latest/bin` 和 `platform-tools`；也可用 SDK 下的绝对路径执行检测。版本查询只证明 CLI 可运行，仍须核对 SDK 列表与命令退出状态；发现 SDK 元数据不兼容时先修复工具，再重复检测。[Android CLI][G25]

Android 工程创建后，通过项目 Wrapper 核对实际 Gradle 版本与运行 JDK，再执行构建。已有全局 Gradle 或缓存不替代项目 Wrapper；已建 AVD、模拟器硬件加速通过也不替代 S24+ 的 Health Connect / Samsung Health 验收。

实施时建立统一名称：iOS shared scheme `HealthRelay`，Android module `app`，fixture 目录 `fixtures/`。可执行验证入口约定为：

```sh
xcodebuild -list -project ios/HealthRelay.xcodeproj
xcodebuild -showdestinations -project ios/HealthRelay.xcodeproj -scheme HealthRelay
xcodebuild test -project ios/HealthRelay.xcodeproj -scheme HealthRelay -destination "$HEALTH_RELAY_IOS_DESTINATION"
```

`HEALTH_RELAY_IOS_DESTINATION` 使用上一命令列出的可用模拟器或测试设备 destination；真实 HealthKit 来源和签名验收仍须在 iPhone 上运行。Android 在 `android/` 目录运行：

```sh
./gradlew --version
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
./gradlew :app:connectedDebugAndroidTest
```

以上工程和验收入口现已建立并执行；命令结果、证据范围和未执行原因统一维护在 [验收记录](../acceptance.md)。第一步可以检测签名/权限、第三步尽早检验三星兼容性，但不能省略后续可靠性要求就交付日常版本。

数据量增加 10 倍时仍按 500 个源变化、100 个 workout UUID 和 1 MiB 帧分页；workout 汇总重读的工作量会随固定起点之后的运动总数增长，这是本期接受的线性成本。设置页显示缓存大小；空间不足时停止新增缓存并保留游标，不靠丢弃未确认操作腾空间。协议与 UI 不提供无界全量载入。

外部依赖失败时的回退：停止发送并保留源数据/未完成状态；家庭 Wi-Fi 不互通时换网络或手动地址；HC 不可用时暂停导入；Samsung 不显示时按其官方设置排错并记录版本证据。若核心显示能力仍不成立，停止扩大实现投入，交付已证实的失败边界并修订方案，不暗中接入付费服务或合作伙伴 SDK。

卸载应用前可使用精确清除功能删除本应用导入；Apple Health 原始数据始终未被修改。清理本应用记录是有数据效果的操作，需要产品内明确确认，不能声称无损回滚所有三星已消费副本。已安装应用的清理按上述产品内流程执行；卸载源代码或回退 Git 文件不会清除设备中的导入记录。

## 13. 证据等级与待真机确认项

| 结论 | 证据/状态 | 负责确认与失败处理 |
| --- | --- | --- |
| 基础 HealthKit 支持免费开发账号，Personal Team 7 天维护 | 已核对 Apple 当前能力表原始图标及账号文档；不是本机安装实测 | 实现者在 iPhone 首次安装记录 entitlement/profile；如本机签名异常，先依据 Xcode 具体错误排错。 |
| HC 支持睡眠、运动、距离和活动能量及 client ID upsert | 已核对 API；API 36 模拟器真实读写/聚合通过，API 34 旧组件历史回读失败，详见验收记录 | 实现者用 HC 真机写入/回读验证。 |
| 三星支持经 HC 读取相关睡眠与运动数据 | 官方支持路径；精细映射和实际显示受版本影响 | 用户与实现者共同完成第 11.2 节；核心不可见则不交付“已完成”。 |
| 活动能量不能直接冒充三星表中的总消耗 | Apple 字段语义与 Samsung 类型表共同支持 | 本期按活动能量写入，三星可留空；不推算静息量。 |
| 睡眠空档/unknown 不能靠留空从 HC 总时长扣除 | 已核对 Android 14 及当前 AOSP 的排除类型与聚合阶段筛选；未在用户组件实测 | 本期在不确定区间拆分；用 C30/C31 和 S24+ 核对时长及分组表现。 |
| 候选分组阈值、睡眠拆分、首次 30 天及重建保留原起点、两原生应用、TLS 配对 | 本项目设计决策，不是平台规定 | 用 fixtures 验证确定性和日常流程；修订时同步更新身份、协议和验收约束。 |
| iOS 授权、历史可见性和 anchor 重建 | API 限制已核对；本机拒绝/恢复行为未测 | 不以缺失推删，按 C17/C26 真机验证。 |
| HealthKit 删除事件定期清理，纯手动同步不保证全部历史删除 | Apple 明确说明事件只临时保留，未给出可依赖的固定天数 | 按 C34 验证待核对状态及默认保留；修复使用用户确认的原范围重建。 |
| 三星阶段展示、距离关联、暂停时长、更新/删除传播、未知 offset 日期归属 | 官方未提供足以保证具体 UI 的承诺 | 在 S24+ 分项记录；不得声称已经验证或静默缩减承诺范围。 |
| IPv4 Wi-Fi 发现、证书固定、后台切换恢复 | 标准平台 API 可实现；本机路由器与 TLS 互操作未测 | 按 C20/C23-C25 测试；手动地址仍使用同一安全协议。 |

## 14. 官方参考资料

以下所有资料均于 **2026-09-12** 核对。Apple 动态 API 页使用其官方 DocC 数据读取正文及系统可用版本；账号能力表读取原始 HTML 中的支持图标。Samsung 的教程用于核对官方列出的数据交换模型，不把历史文章的界面图或版本信息当成当前 S24+ 的实测。Android 以稳定 Jetpack 1.1.0 API 为实现基线，入门页中的 alpha 示例不覆盖本规格的版本选择。

| 编号 | 官方资料与用途 |
| --- | --- |
| A1 | [Apple：Supported capabilities (iOS)][A1]：免费账号的基础 HealthKit 能力。 |
| A2 | [Apple：HKCategoryValueSleepAnalysis][A2]：卧床与阶段重叠语义。 |
| A3 | [Apple：Authorizing access to health data][A3]：读写授权和读取不可见性。 |
| A4 | [Apple：HKWorkout][A4]、[statistics(for:)][A20]：workout 及关联统计。 |
| A5 | [Apple：HKWorkoutActivityType][A5]：原始运动类型。 |
| A6 | [Apple：HKWorkout.totalEnergyBurned][A6]：活动能量语义及弃用替代。 |
| A7 | [Apple：HKWorkout.totalDistance][A7]：距离汇总及弃用替代。 |
| A8 | [Apple：HKMetadataKeyTimeZone][A8]：源记录时区。 |
| A9 | [Apple：Developer account overview][A9]：Personal Team 和 7 天有效期。 |
| A10 | [Apple：HKWorkout.duration][A10]、[HKWorkoutEventType][A21]：时长与暂停事件。 |
| A11 | [Apple：HKAnchoredObjectQuery][A11]：新增/删除增量游标。 |
| A12 | [Apple：TN3179 Local network privacy][A12]：Bonjour、本地网络和 multicast 区别。 |
| A13-A14 | [Apple：NWConnection][A13]、[TLS verify block][A14]：系统 TLS 连接与对端校验。 |
| A15 | [Apple：getEarliestAuthorizedSampleDate][A15]：iOS 27 有限历史读取 API 的版本边界。 |
| A16 | [Apple：HKMetadataKeyIndoorWorkout][A16]：室内标记含义。 |
| A22 | [Apple：HKMetadataKeySwimmingLocationType][A22]：游泳场地语义。 |
| A23 | [Apple：HKHealthStore.delete(_:withCompletion:)][A23]：HKDeletedObject 临时保留及定期清理的边界。 |
| A17 | [Apple：Setting up HealthKit][A17]：capability 与设备可用性。 |
| A18-A19 | [Apple：Program enrollment][A18]、[TestFlight overview][A19]：可选会员费用与测试分发期限。 |
| G1 | [Android：Health Connect releases][G1]：稳定 Jetpack 1.1.0。 |
| G2-G5 | [ExerciseSessionRecord][G2]、[SleepSessionRecord][G3]、[ExerciseSegment][G4]、[Workout experiences][G5]：目标类型、阶段和统计关联。 |
| G6-G9 | [Write data][G6]、[Metadata][G7]、[Delete data][G8]、[HealthConnectClient][G9]：upsert、归因、精确删除、事务边界。 |
| G10-G11 | [NsdManager][G10]、[Android Keystore][G11]：局域网服务发现和密钥存储。 |
| G12-G14 | [Get started][G12]、[Training plans 的权限说明][G13]、[Read raw data][G14]：权限配置、自有数据读取与历史限制。 |
| G15-G16 | [Android 17 行为变化][G15]、[Android 17 SDK 设置][G16]：新本地网络权限与 SDK 门槛。 |
| G17-G18 | [Play Console 注册][G17]、[Publish your health app][G18]：公开分发费用、声明和审核。 |
| G19-G21 | [Android 架构建议][G19]、[Compose BOM][G20]、[Room 配置][G21]：UI 状态、依赖管理与编译插件。 |
| G22-G24 | [Android Studio / AGP 兼容矩阵][G22]、[Java versions in Android builds][G23]、[ServerSocket.close][G24]：SDK 36 工具链、JDK 和阻塞监听退出。 |
| G25-G27 | [Android CLI][G25]、[Gradle Java 兼容矩阵][G26]、[Daemon JVM criteria][G27]：SDK/AVD 命令、Gradle 运行 JDK 兼容性与选择规则。 |
| K1 | [Kotlin Serialization][K1]：有类型的 JSON 编解码与独立库版本。 |
| S1 | [Samsung：Health Connect FAQ][S1]：支持路径、版本和设置排错。 |
| S2 | [Samsung：Accessing Samsung Health Data through Health Connect][S2]：数据类型表、读取方向与版本限制。 |
| S3 | [Samsung Health Data SDK：Developer mode][S3]：合作伙伴、签名匹配和调试模式边界。 |

实现参考（同日检查源代码，不作为 Samsung 能力证明）：[Google HealthConnectSample][R1]、[Stanford SpeziHealthKit QueryAnchor][R2] 与 [HealthKitQuery][R3]。睡眠聚合另核对 Android 14 的 [SleepSessionRecord 排除类型][R4] 与 [SleepStageRecordHelper][R5]，并与当前 AOSP main 实现交叉检查；实际系统组件仍须按验收表测试。

[A1]: https://developer.apple.com/help/account/reference/supported-capabilities-ios
[A2]: https://developer.apple.com/documentation/healthkit/hkcategoryvaluesleepanalysis
[A3]: https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data
[A4]: https://developer.apple.com/documentation/healthkit/hkworkout
[A5]: https://developer.apple.com/documentation/healthkit/hkworkoutactivitytype
[A6]: https://developer.apple.com/documentation/healthkit/hkworkout/totalenergyburned
[A7]: https://developer.apple.com/documentation/healthkit/hkworkout/totaldistance
[A8]: https://developer.apple.com/documentation/healthkit/hkmetadatakeytimezone
[A9]: https://developer.apple.com/help/account/basics/about-your-developer-account
[A10]: https://developer.apple.com/documentation/healthkit/hkworkout/duration
[A11]: https://developer.apple.com/documentation/healthkit/hkanchoredobjectquery
[A12]: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
[A13]: https://developer.apple.com/documentation/network/nwconnection
[A14]: https://developer.apple.com/documentation/security/sec_protocol_options_set_verify_block(_:_:_:)
[A15]: https://developer.apple.com/documentation/healthkit/hkhealthstore/getearliestauthorizedsampledate(for:completion:)
[A16]: https://developer.apple.com/documentation/healthkit/hkmetadatakeyindoorworkout
[A17]: https://developer.apple.com/documentation/healthkit/setting-up-healthkit
[A18]: https://developer.apple.com/programs/enroll/
[A19]: https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview
[A20]: https://developer.apple.com/documentation/healthkit/hkworkout/statistics(for:)
[A21]: https://developer.apple.com/documentation/healthkit/hkworkouteventtype
[A22]: https://developer.apple.com/documentation/healthkit/hkmetadatakeyswimminglocationtype
[A23]: https://developer.apple.com/documentation/healthkit/hkhealthstore/delete(_:withcompletion:)-78l1m
[G1]: https://developer.android.com/jetpack/androidx/releases/health-connect
[G2]: https://developer.android.com/reference/androidx/health/connect/client/records/ExerciseSessionRecord
[G3]: https://developer.android.com/reference/androidx/health/connect/client/records/SleepSessionRecord
[G4]: https://developer.android.com/reference/androidx/health/connect/client/records/ExerciseSegment
[G5]: https://developer.android.com/health-and-fitness/health-connect/experiences/workouts
[G6]: https://developer.android.com/health-and-fitness/health-connect/write-data
[G7]: https://developer.android.com/reference/androidx/health/connect/client/records/metadata/Metadata
[G8]: https://developer.android.com/health-and-fitness/health-connect/delete-data
[G9]: https://developer.android.com/reference/androidx/health/connect/client/HealthConnectClient
[G10]: https://developer.android.com/reference/android/net/nsd/NsdManager
[G11]: https://developer.android.com/privacy-and-security/keystore
[G12]: https://developer.android.com/health-and-fitness/health-connect/get-started
[G13]: https://developer.android.com/health-and-fitness/health-connect/features/training-plans
[G14]: https://developer.android.com/health-and-fitness/health-connect/read-data
[G15]: https://developer.android.com/about/versions/17/behavior-changes-17
[G16]: https://developer.android.com/about/versions/17/setup-sdk
[G17]: https://support.google.com/googleplay/android-developer/answer/6112435?hl=en
[G18]: https://developer.android.com/health-and-fitness/health-connect/publish
[G19]: https://developer.android.com/topic/architecture/recommendations
[G20]: https://developer.android.com/develop/ui/compose/bom
[G21]: https://developer.android.com/training/data-storage/room
[G22]: https://developer.android.com/studio/releases
[G23]: https://developer.android.com/build/jdks
[G24]: https://developer.android.com/reference/java/net/ServerSocket#close()
[G25]: https://developer.android.com/tools/agents/android-cli
[G26]: https://docs.gradle.org/current/userguide/compatibility.html#java_runtime
[G27]: https://docs.gradle.org/current/userguide/gradle_daemon.html#sec:daemon_jvm_criteria
[K1]: https://kotlinlang.org/docs/serialization.html
[S1]: https://developer.samsung.com/health/health-connect-faq.html
[S2]: https://developer.samsung.com/health/blog/en/accessing-samsung-health-data-through-health-connect
[S3]: https://developer.samsung.com/health/data/guide/developer-mode.html
[R1]: https://github.com/android/health-samples/blob/main/health-connect/HealthConnectSample/app/src/main/java/com/example/healthconnectsample/data/HealthConnectManager.kt
[R2]: https://github.com/StanfordSpezi/SpeziHealthKit/blob/main/Sources/SpeziHealthKit/Queries/QueryAnchor.swift
[R3]: https://github.com/StanfordSpezi/SpeziHealthKit/blob/main/Sources/SpeziHealthKit/Queries/HealthKitQuery.swift
[R4]: https://android.googlesource.com/platform/packages/modules/HealthFitness/+/refs/heads/android14-release/framework/java/android/health/connect/datatypes/SleepSessionRecord.java
[R5]: https://android.googlesource.com/platform/packages/modules/HealthFitness/+/refs/heads/android14-release/service/java/com/android/server/healthconnect/storage/datatypehelpers/SleepStageRecordHelper.java
