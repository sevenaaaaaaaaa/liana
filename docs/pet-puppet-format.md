# 松萝纸偶形象包格式（`.lianapet`，format 1）

纸偶（puppet）是松萝自己的开放桌宠格式：**几张图片 + 声明式动作数据**，不依赖 Live2D / VRM，
任何人都能用照片、手绘或 AI 生成的图片做形象、写动作并分享。决策背景见 [ADR-0011](adr/0011-puppet-pet-format.md)。

## 文件结构

`.lianapet` 是一个 zip，根目录：

```
pet.json        渲染器声明 + 图片 + 骨架 + 可选的动作/触发/台词
plugin.json     插件清单（id 必须以 puppet- 开头）
idle.png        「平时」图（必需）
happy.png …     其他表情图（可选）
```

只允许 `png / jpg / jpeg / webp / json`，不允许符号链接，总大小 ≤ 40MB。**包里没有任何可执行代码**。

## plugin.json

```json
{
  "id": "puppet-maple-fox",
  "name": "枫叶狐狸",
  "version": "1.0.0",
  "kind": "pet",
  "authors": ["作者名"],
  "description": "一只会打盹的狐狸",
  "license": "CC-BY-4.0",
  "permissions": []
}
```

## pet.json

```json
{
  "renderer": "puppet",
  "width": 220,
  "height": 300,
  "puppet": {
    "format": 1,
    "faces": "front",
    "rights": "shareable",
    "images": {
      "idle":  { "src": "idle.png",  "rig": { "neck": [0.5, 0.66], "head": [0.22, 0.64, 0.78, 1.0], "ground": 0 } },
      "happy": { "src": "happy.png", "rig": { "neck": [0.5, 0.66], "head": [0.22, 0.64, 0.78, 1.0], "ground": 0 } }
    },
    "actions":  { },
    "triggers": { },
    "states":   { },
    "lines":    { }
  }
}
```

| 字段 | 说明 |
|---|---|
| `faces` | `front` / `left` / `right`：侧身形象溜达时按方向镜像 |
| `rights` | `shareable`（作者声明原创或已获授权，可申请发布到松萝社区）/ `personal`（个人使用；本地使用与导出不受限） |
| `images.<表情>` | 表情：`idle`（必需）`blink`（闭眼，用于眨眼）`talk`（张嘴，说话口型）`happy` `typing` `sleep` `surprised` `shy` `sad` `angry` `love` `tired`；缺的表情按近似表情兜底（angry→sad，love→shy→happy，tired→sleep，shy→happy，最后用 idle）；也可以自定义表情名供自己的动作引用 |
| `images.<表情>.align` | 可选，相对平时图的对齐 `{"s": 缩放, "dx": 左右, "dy": 上下}`（单位 = 平时图显示高度，dy 向上为正）；形象工坊按人脸自动计算，可手动微调 |
| `images.<表情>.generated` | `true` 表示由形象工坊按「平时」图自动生成（目前是 `blink` / `talk`），只和平时图对齐，编辑时会重新生成 |
| `rig.neck` | 脖子转轴（图片归一化坐标，**y 自下而上**） |
| `rig.head` | 头部范围 `[x0, y0, x1, y1]`：范围内随头部转动，范围外平滑衰减 |
| `rig.ground` | 脚底线（裁切到主体时为 0） |
| `rig.eyes` | 可选，眼睛范围 `[[x0, y0, x1, y1], …]`（最多 2 个）：没有 `blink` 图时据此自动生成闭眼图 |
| `rig.face` | 可选，识别到的人脸框，只用于表情图之间的自动对齐 |
| `rig.mouth` | 可选，嘴巴范围 `[x0, y0, x1, y1]`：没有 `talk` 图时据此自动生成张嘴图，说话时嘴巴开合 |

同一组图（如同一次 AI 生成）应构图一致：形象工坊会把尺寸相同、主体位置高度重合的图按同一裁切框处理，切换表情和眨眼时不跳动。

## 动作

动作是一段**关键帧**或**周期波形**，作用在下列通道上（位移单位 = 角色显示高度，角度单位 = 弧度），多个动作叠加求和：

| 通道 | 含义 |
|---|---|
| `root.tx` `root.ty` | 整体平移 |
| `root.rot` | 绕脚底中心旋转 |
| `root.swing` | 绕头顶摆动（被拎起来） |
| `root.sx` `root.sy` | 整体缩放增量（`sx = -2` 等于水平翻面） |
| `breathe` | 呼吸（纵向伸缩并保持体积） |
| `lean` | 身体前后倾（越往上偏移越大，脚底不动） |
| `head.rot` `head.tx` `head.ty` | 头部绕脖子旋转 / 平移 |
| `alpha` | 透明度增量 |

```json
"actions": {
  "tail_wag": {
    "name": "摇尾巴",
    "duration": 1.2,
    "image": "happy",
    "say": ["汪！"],
    "effect": "hearts",
    "tracks": {
      "root.rot": [[0, 0], [0.3, 0.05], [0.6, -0.05], [0.9, 0.04], [1.2, 0]],
      "breathe":  { "sin": [0.02, 2.0] }
    }
  }
}
```

- 关键帧：`[[时间秒, 值], …]`，默认平滑插值；`"ease": "linear"` 改为线性。
- 波形：`{"base": b, "sin": [振幅, 频率Hz, 相位], "bob": [振幅, 频率Hz]}`（`bob` 是 |sin|，适合跳跃/走路）。
- `image`：动作期间切换到的表情图；`say`：随机说一句；`effect`：`hearts` / `sparks`；`emote`：头顶冒的情绪符号（如 `💢` `❤️`）。
- `loop: true`：循环动作，用作状态底色（见 `states`）。
- `walk: 1.4`：溜达若干个身位（用户开启「允许四处溜达」时才移动窗口）。

预置动作库见 `platforms/macos/assets/PetRuntime/puppet/actions.json`（点头、摇头、开心蹦跶、害羞、吓一跳、转个圈、东张西望、伸懒腰、歪头探看、打招呼、欢呼、跺脚、委屈、溜达……），包里同名动作会覆盖预置。

## 触发与状态

```json
"triggers": {
  "click": ["tail_wag", "happy_bounce"],
  "double_click": ["surprised_jump"],
  "idle": ["look_around", "tail_wag"]
},
"states": { "sleep": "my_sleep_loop" },
"lines": { "click": ["别摸啦", "嘿嘿"] }
```

触发器：`click` 摸头、`double_click` 戳一戳、`hover` 悬停、`commit` 上屏、`idle` 闲时随机、`roam` 溜达、
`greet` 问候、`milestone` 字数里程碑、`wake` 醒来、`drop` 放下、`break` 休息提醒；
情感类：`love` 连着摸头、`angry` 被连戳、`lonely` 被冷落、`welcome` 离开后回来、`comfort` 删字很多、`dizzy` 被鼠标晃晕、`shy` 一直盯着它、`night` 深夜还在打字、`scared` 受惊。
值为动作 id 或 id 数组（随机挑一个）。

状态：`idle` / `typing` / `sleep` / `drag` → 循环动作 id。

台词键：上面的触发器名，以及 `morning` `afternoon` `evening` `sleep` `wake` `level`。

## 形象源

官方形象源是**松萝社区**（`https://nownexts.com/api/pets`，即 nownexts.com 生态市场的「桌宠」分类），客户端内置、不可移除：
认证开发者在会员中心上传 `.lianapet`，审核通过后上架；只收原创或已获授权的形象，可免费也可定价。
此外，任何人都可以把 `.lianapet` 放在任意 https 地址上，再发布一份 `index.json` 作为**形象源**；
用户在「形象源」窗口里自己添加想订阅的地址（客户端不内置任何形象源）：

```json
{
  "format": 1,
  "packs": [
    {
      "id": "puppet-maple-fox",
      "name": "枫叶狐狸",
      "author": "作者名",
      "license": "CC-BY-4.0",
      "description": "一只会打盹的狐狸",
      "url": "https://example.com/pets/puppet-maple-fox.lianapet",
      "preview": "https://example.com/pets/puppet-maple-fox.png",
      "sha256": "…64 位十六进制…",
      "bytes": 812345,
      "tags": ["动物", "原创"]
    }
  ]
}
```

可选字段：`price`（大于 0 为付费形象，此时不给 `url`，改给 `page` 购买页；用户在网页购买、下载后双击 `.lianapet` 导入）。

客户端只收 `puppet-` 前缀、带 sha256 的条目，免费的要有 https `url`、付费的要有 https `page`；下载后 sha256 不符直接丢弃。
计算 sha256：`shasum -a 256 puppet-maple-fox.lianapet`。

## 版权

本地使用不干预：用什么图片做形象、导出发给谁，都由用户自己决定。
发布到松萝社区（nownexts.com）只收原创或已获授权的形象（`rights: shareable`），并经过审核。
第三方形象源的内容由发布者自行负责。
