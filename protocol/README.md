# 协议与合成契约

需求与状态机的权威定义是 [spec §8–9](../docs/specs/spec.md#8-同步状态幂等修改和删除)。`v1.schema.json` 是其机器可读结构约束；跨字段身份、时间区间、连续阶段、来源 SHA-256、版本和认证状态仍由 Swift `Contract` / Kotlin `Wire` 校验。规范化只发生在 iOS，Android 不修正非法健康 payload。

- UTF-8 JSON 前是四字节大端长度，1–1,048,576 字节。TLS 1.3，固定扫码取得的叶证书。
- 响应信封包含 `protocolVersion`、`type: "result"`、原 `requestId`、`ok`；失败为 `error: {code, retryable}`。
- 请求与响应一次只允许一个在途；`applyBatch` 按组隔离解析和结果。当前发送器逐组传送，每帧一组，接收器上限 25 组。
- 版本使用 Swift Int64 / Kotlin Long。JSON 字节排列不构成跨平台哈希契约；接收器对解码后的确定性结构独立算摘要。
- `source` 的缺失元数据和未知 offset 为显式 null；统计缺失用 `state: unavailable`。传输 null 不保证 Android 14+ 内部保存 null，见 [实际平台边界](../docs/acceptance.md)。
- `:session`、`:distance`、`:active-energy` 由接收端派生，不接受任意目标 record ID。

共享用例位于 [fixtures](../fixtures)。`sleep-normalization.json` 的 input 是源端合成输入，expected 是双方校验的目标契约；Kotlin 不再次执行睡眠规范化。`workout.json` 包含大于 IEEE-754 精确整数范围的版本、null 元数据、距离和活动能量。`invalid-contract.json` 包含拒绝用例。测试数据完全合成，不从设备生成。

更新结构后运行 `python3 scripts/make-protocol-schema.py`；只有需要变更合成用例时才运行 `python3 scripts/make-fixtures.py`。两个脚本不读取健康数据库。
