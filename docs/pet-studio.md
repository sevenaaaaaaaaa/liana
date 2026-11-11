# 本地桌宠定制工作台

入口：桌宠菜单 → 形象工坊 → **定制工作台**。无需配置服务或 API Key，就能导入一张图、调整骨架与动作、修整透明边缘、预览并保存形象包。

## 最快做出一个桌宠

1. 在「形象」中将透明 PNG 放入「平时」。普通照片会尝试本机 Vision 抠图，卡通脸识别不到时手动调整脖子与头框。
2. 在「定制工作台」选安静陪伴、自然灵动或活泼弹跳，调动作幅度、速度、视线跟随。左侧按钮可试播现有动作。
3. 在黑、白、绿三种底色上检查选中图片的边缘。低强度收边适合头发和绒毛；素材来自白底时再开启白边净化。每次从会话内首次修整前的图计算，随时恢复，保存后关闭工坊则以保存图为准。
4. 在「动作与互动」中改关键帧、触发器和台词，最后点「保存并使用」，或导出 `.lianapet`。

呼吸、歪头、弹跳等由网格变形生成，无需为每个动作准备图片。单图不能生成真实的背面、换装或遮挡后的身体结构；这些需要补充姿势图、Live2D 分层素材或 VRM 模型。装饰场景道具默认关闭，角色的场景互动仍保留；工作台中可以单独开启道具。

## 用 MiniMax、Anthropic、兼容服务设计动作

选择服务后填写实际模型 ID。MiniMax 采用 OpenAI 兼容的 `/chat/completions` 协议，默认基础地址 `https://api.minimax.io/v1`；Anthropic 使用 `/messages` 协议，默认 `https://api.anthropic.com/v1`。其他兼容服务支持自定义基础地址，本地 HTTP 仅接受 localhost/127.0.0.1/::1，其余使用 HTTPS。

API Key 存入系统钥匙串；制作配置留在本机偏好中。点击生成时发送制作描述和动作格式；该接口不发送输入法组合串、聊天记录或参考图片。云服务可能收费。图像参考生成仍走原有「形象 → AI 补全表情」，会单独要求上传图片的同意。

Codex CLI 路线填写本机 `codex` 可执行文件的绝对路径，可用 `command -v codex` 查找。它使用现有登录配置与可选模型 ID，通过 `codex exec --sandbox read-only` 输出动作 JSON；运行日志与结果留在本机任务目录。工坊不会替你安装或登录 CLI。

生成结果先停在 JSON 编辑区。点击「校验并加入草稿」后，才会进入动作编辑器；点击「保存并使用」后才更换桌宠。也可以粘贴 JSON，或从其他工具导入 JSON。

```json
{
  "actions": {
    "studio_nod": {
      "name": "点头回应",
      "duration": 1,
      "tracks": {
        "head.rot": [[0, 0], [0.3, 0.12], [0.65, -0.04], [1, 0]]
      }
    }
  },
  "triggers": {"click": ["studio_nod"]},
  "lines": {"greet": ["我来陪你啦"]}
}
```

动作 ID 以 `studio_` 开头；最多 12 个动作，时长 0.1–12 秒；每轨 2–32 帧，时间严格递增且起止回到零。未知通道、超范围数值、悬空动作引用和代码字段会被拒绝。当前生成接口支持关键帧，循环波形可用形象包原有声明式格式编写。

## 连接图像、视频、3D 工具

每次任务独立保存到 `~/Library/Application Support/Liana/PetStudio/Jobs/<UUID>/`：

- `job.json`：描述、形象名称、参考图文件名、可选视频或 3D 工程 `source` 的本机路径，以及输出约定。
- `<role>.png`：当前草稿参考图。纯动作模型任务不会复制这些图。
- `output/`：工具成品目录。
- `tool-<UUID>.log`：本地工具日志。

执行入口与参数由用户在工作台配置，形象包和模型输出都不能指定程序。参数使用 JSON 字符串数组，直接作为 argv 传入，不经过 shell。支持 `{job}`、`{dir}`、`{output}` 三个占位符。执行时按下「运行配置的工具」才会调用；工具本身是否访问网络取决于你配置的程序。

内置两个可修改模板：

| 模板 | 输入 | 输出 | 本机要求 |
|---|---|---|---|
| 视频拆帧 | 选择视频 | 2 秒内、6fps 的 PNG 帧 | Python 3、FFmpeg；修改模板中的 FFmpeg 实际路径 |
| Blender 透明渲染 | 有摄像机和姿势/动作的 `.blend` | 最多四张 RGBA 姿势图 | Blender；修改可执行文件位置，复杂工程可修改脚本 |

视频拆帧不会自动变成连续视频桌宠：选择代表帧，分配给平时、打字、开心等状态，其余动效交给参数动作。Blender 模板读取已有场景并关闭脚本自动运行，不会凭空生成 3D 模型或装好 VRM 导出插件。

ComfyUI、其他平面工具或视频/3D 服务可用自己的 Python/CLI 包装器读取 `job.json`，将图片、`.lianapet` 或 `.vrm` 放进 `output/`，再点「导入成品」。API 的异步生成、轮询、下载和格式转换由包装器负责，工坊不假设不同服务共用一种接口。图片进入当前草稿，纸偶包载入工坊，VRM 安装进形象库后从桌宠菜单选择。GLB、视频和 Live2D 工程走各自制作/导入流程。

任务与日志不会自动上传，可在 Finder 打开和删除。分享 `.lianapet` 只包含图像和声明式动作，不包含 API Key、工具程序路径或本机任务文件。

## 验证

```bash
cargo test
cargo run -p xtask -- accuracy
cargo run -p xtask -- accuracy --hard
swiftc platforms/macos/Sources/PetStudioCore.swift platforms/macos/tests/PetStudioTests.swift -o /tmp/liana-studio-tests
/tmp/liana-studio-tests
UNIVERSAL=0 ./platforms/macos/build.sh
```

协议依据：[MiniMax OpenAI 兼容接口](https://platform.minimax.io/docs/api-reference/text-openai-api)、[Anthropic Messages](https://platform.claude.com/docs/en/api/messages)、[Codex CLI 参数](https://learn.chatgpt.com/docs/cli/reference)。实际云端调用需要用户自己的账户、可用模型与密钥；协议测试使用本地模拟响应。
