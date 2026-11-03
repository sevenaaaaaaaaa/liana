# ADR-0005：用户数据加密持久化与剪切板历史

状态：已接受（M1）

## 背景

M0 的用户词只在内存，重启即失；候选重排与「上下词预测」需要跨会话记忆。
剪切板历史是高频需求，但剪切板内容极其敏感（密码、验证码、私聊），必须默认关闭、
加密落盘、可一键清空。

## 决策

### 存储容器

- 主档：`~/Library/Application Support/Liana/userdata.enc`，权限 0600。
- 格式：`magic("IFUE") + version(1) + ChaChaPoly combined(nonce ‖ ciphertext ‖ tag)`；
  头部作为 AEAD 的 AAD 一并认证，防止版本降级/篡改。
- 明文载荷是 JSON（`userModelTsv` + `evolutionTsv` + `nutritionTsv` + `clipboard` 数组），
  带 `schemaVersion` 字段；解析失败视为无数据，不阻塞输入。
- 写入为**原子替换**（同目录临时文件 + rename），避免断电留下半截文件。
- v4 起剪切板历史拆到 `userdata.clip.enc`（同一密钥、同一格式），主档只放用户词/账本：
  剪切板历史可达数 MB，跟着主档一起重加密会让每次上屏/落盘都重写整份历史。
  旧档（v3 及更早，剪切板在主档里）加载时就地迁移，写盘顺序为先剪切板后主档。
- 写盘在串行后台队列执行：主线程只做快照，JSON 编码 + 加密 + 原子写（用户词上万条时
  可达上百毫秒）不阻塞按键；进程退出前同步写完（`flush()`）。

### 密钥管理

- 256-bit 随机密钥存 macOS 钥匙串（`kSecClassGenericPassword`，
  service `dev.inputflow.inputmethod`，account `userdata-key`，
  `kSecAttrAccessibleAfterFirstUnlock`）。
- 钥匙串不可用（例如未签名/沙箱限制）时**不静默降级**：本次运行不持久化，
  并在日志中说明原因；绝不把密钥写到数据文件旁边。
- 换密钥 = 删除钥匙串条目与 `userdata.enc`（UI 提供「清除本地数据」）。

### 剪切板历史

- **默认关闭**；开启后仅保留最近 200 条、单条 ≤ 100 KB，超出丢弃；存于 `userdata.clip.enc`。
- 跳过系统标记为 Concealed/Transient 的内容（`org.nspasteboard.ConcealedType`、
  `org.nspasteboard.TransientType`，密码管理器使用），跳过连续重复项。
- 不记录来源 App、不记录时间线之外的元数据；时间戳仅用于展示排序。
- 仅本机、仅加密文件；同步协议里的剪切板 op 仍是 M3 的独立开关（默认关闭）。
- 一键清空：删除内存与文件中的历史（用户词保留）。

### 失败行为

- 解密失败/文件损坏：当作空数据处理，备份坏文件为 `userdata.enc.corrupt`（用户可删），
  继续正常输入。
- 钥匙串读取被拒绝：提示一次，本次运行退化为「仅内存」。

## 结果

- 好：用户词与二元组预测跨会话生效；剪切板敏感数据有明确的开关与加密边界。
- 代价：钥匙串条目与设备绑定，跨设备迁移需走 M3 的同步协议（而不是拷文件）。
- 验证方式：`ls -l` 看 0600；`grep -a` 明文搜索文件应无结果；断网可用。
