# 阅卷辅助小助手 项目说明文档

> **简介**：面向电脑阅卷的桌面自动化助手。在浏览器旁一条窄长侧边窗口里运行：框选学生答案区域后自动截图、识别作答内容，调用 DeepSeek 按标准答案**逐要点判分**，把分数写进阅卷页面的「得分」框；开启**连续批阅**后还会自动提交、等待页面跳到下一题，逐题完成整份试卷。全程**不访问、不爬取、不逆向阅卷系统接口**，只做屏幕截图与模拟鼠标键盘；识别与成绩数据存本地 SQLite；AI 分数强制取整、仅作参考，**最终成绩以教师确认为准**。

>
> 项目名称：阅卷辅助小助手
> 包名（pubspec name）：`judge_assistant`
> 开发框架：Flutter Desktop（Dart）
> 支持平台：Windows 11、macOS（仅桌面端；仓库中的 `android/`、`ios/` 为 `flutter create` 模板残留，不参与构建，可删除）
> 应用场景：配合 Chrome 浏览器内的电脑阅卷系统使用，侧边细长竖窗口辅助阅卷；所有业务数据本地 SQLite 存储，无后端服务器。

## 1. 项目概述

本软件是桌面端阅卷辅助工具，采用窄长竖窗口布局，放置在 Chrome 浏览器右侧，不遮挡阅卷网页。软件仅对屏幕上的阅卷页面进行区域截图识别文字，**不访问阅卷系统接口、不爬虫、不逆向平台**，规避阅卷系统的防爬限制。

工作逻辑：

1. 用户框选网页上的学生答案区域进行截图；
2. **默认使用本地 PaddleOCR 离线识别图片文字，图片不上传外网**；
3. 当本地 OCR 识别效果差（学生字迹潦草），教师可以手动点击兜底按钮，调用 DeepSeek 多模态模型识别图片文字；该操作会弹窗确认，确认后才将截图上传 DeepSeek；
4. 文字识别完成后，使用 DeepSeek 文本模型做 AI 辅助打分；**每道题目独立发起 API 请求，不带任何上一题上下文，防止上下文累积膨胀**；
5. 识别文本、AI 参考分数、教师修改分数全部保存在本地 SQLite；AI 分数仅作参考，**最终成绩以教师手动录入的分数为准**。

## 2. 功能需求

### 2.1 窗口功能

- 窄长竖长方形侧边窗口，支持窗口置顶，可放在浏览器右侧；支持最小化。

### 2.2 截图功能

- 区域框选截图：仅截取当前学生答案区域；
- 截图保存到**应用支持目录下的 screenshots 子目录**（`path_provider` 的 `getApplicationSupportDirectory()/screenshots/`），UI 上展示截图预览图；
- **禁止写入 `assets/` 目录**：Flutter 打包后的 assets 为只读，运行时不可写。

### 2.3 文字识别（双模式，手动选择）

1. **本地 OCR（默认优先）**
    - 调用本地 OCR 可执行程序（协议见 §4.3；仓库自带 macOS 版 `tools/ocr_vision`）；
    - 图片全程本地处理，**不上传图片到外网**；
    - 识别结果填入【学生答案】输入框（见 §3.3 填充约定）；
2. **DeepSeek 多模态视觉识别（兜底，手动触发）**
    - 仅教师主动点击按钮才执行；
    - 点击后弹出确认提示框，告知用户本次操作会将截图上传 DeepSeek 服务器，提供确认 / 取消选项；
    - 调用 `deepseek-flash`（Vision）识别图片，提取学生作答内容并覆盖【学生答案】；
    - 网络断开时，该按钮置灰，不可点击。

>
> 两种识别方式输出的【题目】、【学生答案】文本框都支持人工编辑，用来修正识别错误。

### 2.4 AI 辅助判分功能

- 使用 DeepSeek 文本模型进行阅卷打分（默认 `deepseek-v4-pro`，可配置切换为 `deepseek-flash` 省成本）；
- 每题独立 API 请求，不携带历史对话内容；
- 判分请求**开启 thinking 推理**（`reasoning_effort: low`，兼顾准确与速度）：实测比关闭时更准、更一致；因为 JSON Output 仅支持非思考模式，这里改为在提示词里约束 JSON 输出；
- **分数为整数**：判分按命中要点比例算分后**四舍五入取整**，不出现小数分；
- **基于语义的逐要点判分**：提示词要求先拆出标准答案的得分要点（要点只能来自标准答案，严禁把题干现象当要点），再逐条判断学生答案是否表达了该要点的具体含义——表达了就得分（含近义表达）；若要点由「结论＋成因」组成，**只要结论答到就算命中、成因说错不扣**；只笼统提现象不算命中。已命中的要点不因答案里另有错误而被扣掉。既避免"一票否决"，也避免"关键词沾边就给分"；
- 自动校验 AI 返回分数：`0 ≤ ai给的分数 ≤ 本题总分`，超出范围自动修正；
- `老师给的分数`默认填充 AI 返回分数，教师可以自由修改，此字段为最终有效成绩；
- **判分后会模拟点击浏览器「得分」框并键盘输入该分数**（需已标定「得分框」并授予「辅助功能」权限）；若【连续批阅】开关为开，还会继续点「提交分数」按钮并等待翻页。

### 2.5 本地数据持久化（SQLite）

全部数据存储在本地 SQLite 数据库，不上传到远端服务器。

1. 阅卷记录表：存储题目、学生答案、标准答案、总分、AI 分数、教师分数、截图路径、识别来源标记、创建时间；
2. 软件配置表：存储 DeepSeek API Key、PaddleOCR 程序路径、判分模型名等配置信息；
3. API 密钥保存在本地数据库，**不硬编码写在源代码内**；
4. **已知风险：** SQLite 为明文存储，`deepseek_api_key` 不做加密。若要进一步提升安全性，可改用系统钥匙串（macOS Keychain / Windows Credential Manager）保存，或对 `config_value` 做对称加密；至少在 UI 展示与日志、错误弹窗中对 Key 脱敏（见 §6.7）。

### 2.6 UI 交互（从上至下竖窗口布局）

1. 自动化面板：【开始自动阅卷】/【停止】按钮、【连续批阅】开关、**刷新间隔滑块（1~20 秒）**、**提交延迟滑块（1~10 秒）**、识别方式选择、标定 / 清除标定按钮（见 §2.7）
2. 截图预览图片组件
3. 操作按钮组：【框选截图】、【本地 OCR 识别】、【DeepSeek 视觉重识别】
4. 可编辑文本框：题目（留空，不参与判分）
5. 可编辑文本框：学生答案（识别结果填入此处）
6. 可编辑文本框：标准答案（教师手动输入）

>
> 上面三个多行文本框都**可拖动下方横条调整高度**，方便查看/编辑内容较多的答案。
7. 数字输入框：该题的总分（教师手动输入）
8. 按钮：【AI 判分】
9. 只读展示：ai 给的分数
10. 可编辑数字输入框：老师给的分数
11. 操作按钮组：【保存本题】、【下一题】
12. 折叠配置面板：DeepSeek API Key 输入框、本地 OCR 程序路径、视觉/判分模型名（可选）
13. 折叠日志面板：记录**发给 AI 的请求体**、AI 返回内容、本地 OCR 输出等，支持复制 / 清空

### 2.7 自动阅卷（一键流程）

> 相比逐题手动操作，点一次【开始自动阅卷】即自动完成后续步骤（自动化模式）。

**引导式标定（首次 / 未标定时）**

点【开始自动阅卷】时，先检查三项坐标（学生答案区域、得分框、提交按钮）是否已标定：

- **已标定** → 直接开始阅卷，不再重复标定；
- **未标定** → 自动截取当前整屏并弹出全屏标定向导，一次性完成三步（带鼠标准星、已标定处的圆点/高亮框与步骤指示）：
  1. 单击浏览器里的「得分」输入框 → 自动进入下一步；
  2. 单击浏览器里的「提交分数」按钮（仅开启自动提交时才需要）→ 自动进入下一步；
  3. 拖拽框选学生的答案区域 → 松手即视为完成。

> 学生答案位置固定，标定一次即可长期复用；程序**不涉及题干**（截图里只有学生作答内容）。

全部完成后底部出现【重新标定】【确认标定】：点【确认标定】保存并继续自动阅卷，点【重新标定】从第一步重来；随时可【取消】或按 Esc 退出。

标定结果保存在本地配置表（`automation_config`），之后【开始】直接复用。需要重新标定时，点面板上的【清除标定】清除后再点【开始】，或用【标定学生答案区域】/【标定得分框】/【标定提交按钮】单独重标。

点【开始自动阅卷】后自动执行：

1. 按标定的学生答案区域截图（自动隐藏本程序窗口，避免入镜）；
2. 识别：按【识别方式】选择「本地 OCR」或「视觉」，结果填入【学生答案】（【题目】留空）；
3. 用界面上已填的【标准答案】与【该题的总分】调用 DeepSeek 判分，分数经 `clamp(0, 总分)` 校验；
4. 把 AI 分数写入界面【老师给的分数】，并**模拟鼠标键盘**把分数写入浏览器「得分」框（双击得分框聚焦 → `Cmd+A` 清空 → 粘贴分数，避免拼接旧值）；
5. **【连续批阅】开关打开时**：等待**「提交延迟」**（面板滑块 **1~10 秒，默认 1 秒**）后模拟点击「提交分数」按钮，然后等待阅卷系统自动跳到下一题，再回到第 1 步处理下一题，直到你点【停止】或检测不到页面刷新；开关**默认关闭**，此时只处理当前题、填分但不提交；
6. 每条记录写入本地 SQLite。

**页面刷新检测（连续批阅时）**

程序读不到网页内容，只能看屏幕：提交后按**「刷新间隔」**（面板上滑块可调，**1~20 秒，默认 2 秒**）截取一次学生答案区域，与上一题的截图比对——当*内容明显变化*（确已换题）且*相邻两次几乎一致*（页面已加载稳定）时，即认为新题就绪，继续处理；总超时约 60 秒，超时则停止连续批阅并在日志里记录。

>
> 说明：本流程中【标准答案】与【该题的总分】仍需每题录入一次（见 §2.4）；同一份试卷可复用（【下一题】不会清空这两项）。

## 3. 数据结构定义

### 3.1 单题 JSON 结构（固定 6 个 key）

```json
{
  "题目": "",
  "学生答案": "",
  "标准答案": "",
  "该题的总分": 0,
  "ai给的分数": 0,
  "老师给的分数": 0
}
```

字段说明：

- `题目`：题干，OCR / 多模态识别获取，支持人工修改
- `学生答案`：学生手写作答内容，OCR / 多模态识别获取，支持人工修改
- `标准答案`：教师手动录入
- `该题的总分`：本题满分，教师录入
- `ai给的分数`：DeepSeek 文本模型返回的参考分数，不能大于该题总分，默认 0
- `老师给的分数`：最终得分，默认等于 ai 给的分数，教师可修改，以此字段作为最终成绩

>
> 该 JSON 是 UI / 接口层的交换结构；落库时还会额外记录 `screenshot_path`、`ocr_source`、`create_time` 三列（见 §3.2），二者字段并不完全对应。

### 3.2 SQLite 数据表

#### 表 1：exam_question_records 阅卷记录表

| 字段名 | 类型 | 说明 |
| --- | --- | --- |
| id | INTEGER PRIMARY KEY AUTOINCREMENT | 自增主键 |
| question | TEXT | 题目 |
| student_answer | TEXT | 学生答案 |
| standard_answer | TEXT | 标准答案 |
| total_score | REAL | 该题总分 |
| ai_score | REAL | ai 给的分数 |
| teacher_score | REAL | 老师给的分数，最终得分 |
| screenshot_path | TEXT | 本地截图文件绝对路径 |
| ocr_source | TEXT | 识别来源：`local_paddle` / `deepseek_vl` |
| create_time | TEXT | 记录创建时间（ISO-8601） |

#### 表 2：app_config 配置表

| 字段名 | 类型 | 说明 |
| --- | --- | --- |
| id | INTEGER PRIMARY KEY AUTOINCREMENT | 主键 |
| config_key | TEXT UNIQUE | 配置项唯一键 |
| config_value | TEXT | 配置值 |

约定的 `config_key`：

| config_key | 说明 | 示例 |
| --- | --- | --- |
| `deepseek_api_key` | DeepSeek API Key（必填） | `sk-...` |
| `paddle_ocr_path` | 本地 OCR 可执行文件绝对路径（必填） | `<仓库>/tools/ocr_vision/bin/ocr_vision` |
| `deepseek_vl_model` | 视觉识别模型名（可选） | `deepseek-flash` |
| `deepseek_judge_model` | 判分模型名（可选） | `deepseek-v4-pro` |

建表 SQL 语句：

```sql
CREATE TABLE IF NOT EXISTS exam_question_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  question TEXT,
  student_answer TEXT,
  standard_answer TEXT,
  total_score REAL,
  ai_score REAL,
  teacher_score REAL,
  screenshot_path TEXT,
  ocr_source TEXT,
  create_time TEXT
);

CREATE TABLE IF NOT EXISTS app_config (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  config_key TEXT UNIQUE,
  config_value TEXT
);
```

### 3.3 OCR 输出与表单填充约定

>
> 本阅卷系统截取的区域只有学生作答内容、**没有题干**，因此识别结果一律填入【学生答案】，【题目】文本框留空、不参与判分。

**DeepSeek 多模态（`deepseek_vl`）**：要求模型返回 JSON（见 §4.2），取其中的「学生答案」填入【学生答案】；若模型未返回该字段，则退回用「题目」字段内容。

**本地 PaddleOCR（`local_paddle`）**：输出连续全文（`full_text`），整体填入【学生答案】（保留换行）。

## 4. 技术选型与外部接口

### 4.1 技术栈

| 模块 | 技术 |
| --- | --- |
| 开发框架 | Flutter Desktop（Dart） |
| 窗口管理 | window_manager（置顶、尺寸、位置、最小化） |
| 区域截图 | desktop_screenshot + 自绘全屏透明框选遮罩层 |
| 本地 OCR | 独立可执行程序（协议见 §4.3），`dart:io` 的 `Process.run` 子进程调用；仓库自带 macOS 版 `tools/ocr_vision` |
| 网络请求 | http |
| 网络状态 | connectivity_plus（或 TCP 探活 `api.deepseek.com:443`） |
| 本地数据库 | sqflite_common_ffi（SQLite） |
| 路径 | path_provider（截图落盘目录） |
| AI 接口 | DeepSeek API（OpenAI 兼容格式） |
| 输入模拟（自动化） | `dart:ffi` 调用 CoreGraphics `CGEvent`（模拟鼠标点击 / 键盘输入，仅 macOS） |

### 4.2 DeepSeek API 约定

官方文档：<https://api-docs.deepseek.com/>

| 项 | 值 |
| --- | --- |
| Base URL | `https://api.deepseek.com` |
| 接口 | `POST /chat/completions` |
| 鉴权 | `Authorization: Bearer <deepseek_api_key>` |
| 协议 | OpenAI Chat Completions 兼容 |

**当前模型（2026-10 核对）：**

| 用途 | model id | 能力 | 默认 |
| --- | --- | --- | --- |
| 视觉识别（兜底 OCR） | `deepseek-flash` | Vision ✓，多图、base64/URL 输入 | 默认 |
| 文本判分 | `deepseek-v4-pro` | 纯文本，推理更强 | 默认（可改 `deepseek-flash`） |

>
> 说明：旧名称 `deepseek-chat`、`deepseek-reasoner` 已于 2026-07-24 停用；`deepseek-v4-flash`、`deepseek-v4-flash-vision-exp` 已退役（请求由最新的 Flash 模型承接），**都不要在新代码里使用**。`deepseek-flash` 由 DeepSeek-V4.1-Flash 服务，多模态与文本能力统一。
>
> 关键能力差异（务必注意）：**Thinking 模式默认开启**（默认 effort = high）；而 **JSON Output 仅支持非思考模式**。因此凡是要用 `response_format: {"type": "json_object"}` 的请求，都必须同时显式设置 `"thinking": {"type": "disabled"}`。

**视觉识别请求（图片以 base64 内嵌，不经过第三方图床，仅随本次请求发给 DeepSeek API）：**

```json
{
  "model": "deepseek-flash",
  "messages": [
    {
      "role": "user",
      "content": [
        {"type": "text", "text": "识别图中学生的手写作答内容，严格输出 JSON：{\"学生答案\":\"...\"}"},
        {"type": "image_url", "image_url": {"url": "data:image/png;base64,<BASE64>", "detail": "original"}}
      ]
    }
  ],
  "thinking": {"type": "disabled"},
  "response_format": {"type": "json_object"},
  "max_tokens": 1024,
  "stream": false
}
```

- 支持图片格式：JPEG / PNG / GIF / WebP；截图统一存 PNG。
- 请求体上限 48 MiB，单图上限 32 MiB（base64 内嵌）；单图 token 上限约 1024。
- 图片只能放在 `user` 消息里（放在 `system` / `assistant` 会返回 400）。
- 视觉识别**必须关闭 thinking**（`"thinking": {"type": "disabled"}`）：一是降低延迟与费用，二是 `response_format: json_object` 仅在非思考模式可用。若确实需要开启 thinking，必须同时去掉 `response_format`，改为在 prompt 中约束 JSON 输出（稳定性更差，不推荐）。
- JSON Output 还要求设置合理的 `max_tokens` 以防 JSON 被中途截断；官方提示该模式偶发返回空 `content`，需按「解析失败」处理（见本节「通用错误处理」）。

**判分请求（纯文本，单题独立）：**

```json
{
  "model": "deepseek-v4-pro",
  "messages": [
    {"role": "system", "content": "你是严格的阅卷老师，只输出 JSON……先拆出标准答案要点，再逐条比对学生答案是否命中，命中即给分；无关或错误内容不会让已命中要点作废，不得因此清零。"},
    {"role": "user", "content": "题目：…\n学生答案：…\n标准答案：…\n该题总分：10\n请逐要点比对后给 0 到 10 之间的分数。输出：{\"score\": <number>, \"reason\": \"<命中了哪些要点、未命中哪些>\"}"}
  ],
  "thinking": {"type": "enabled"},
  "reasoning_effort": "low",
  "max_tokens": 4096,
  "stream": false
}
```

- **判分开启 `"thinking": {"type": "enabled"}`**：判分需要推理，实测开启 thinking 比关闭更准、更一致（关闭时容易低估分数）；
- **`"reasoning_effort": "low"`**：默认 high 思考过多（实测单题 60s+、思考 5000+ tokens），降到 low 后单题约 5~17s，判分结果与 high 基本一致；
- **不用 `response_format`**：JSON Output 仅支持非思考模式，因此改为在提示词里约束 JSON 输出（解析端对多余文字有兜底）；
- **分数必须是整数**：提示词要求按命中要点比例算分后**四舍五入取整**，不出现小数分；
- **请求超时 120s**；
- **不携带历史 messages**，每题全新请求；
- 返回 JSON 解析出 `score`，再执行 `clamp(score, 0, total_score)`；
- 解析失败、超时、非 2xx、限流（429）→ 弹窗提示，不写库。

**通用错误处理：** 视觉识别请求超时 90s、判分请求超时 120s；捕获 `SocketException` / `TimeoutException` / HTTP 非 2xx / JSON 解析失败 / 响应 `choices` 或 `content` 为空（thinking 判分若 max_tokens 不足会返回空内容），统一弹窗。

### 4.3 本地 OCR 子进程协议（约定）

本程序通过子进程调用一个**本地 OCR 可执行程序**，与其约定下面的协议（具体实现不限）。

>
> **仓库自带实现 `tools/ocr_vision`：** 基于 macOS Vision 框架（`VNRecognizeTextRequest`），**离线、支持中文、无需任何第三方依赖**。编译：
>
> ```bash
> bash tools/ocr_vision/build.sh    # 产物：tools/ocr_vision/bin/ocr_vision
> ```
>
> 若你已有 PaddleOCR：官方 CLI 不会输出下面的 JSON，需要自建一个**包装程序**（wrapper，Python / Go 等）在内部调用 PaddleOCR 并整理成该 JSON 从 stdout 输出；配置项填的是这个可执行程序的路径。

**调用：**

```
<本地 OCR 程序> --image "图片绝对路径" --lang ch
```

**stdout 约定为 JSON：**

```json
{
  "code": 0,
  "message": "ok",
  "full_text": "第一行识别文本\n第二行识别文本",
  "lines": ["第一行识别文本", "第二行识别文本"]
}
```

- `code == 0`：成功，取 `full_text` 填充表单（§3.3）；
- `code != 0` 或 stdout 非合法 JSON：弹窗报错，提示检查程序路径与参数；
- 子进程超时 60s；退出码非 0 时优先读取 stderr 作为错误信息。

### 4.4 区域截图实现说明

1. 点击【框选截图】后，创建**全屏透明置顶无边框窗口**覆盖屏幕；
2. 鼠标拖拽绘制矩形选区，支持 Esc 取消；
3. 确认后记录选区的**全局屏幕坐标**，关闭遮罩窗口；
4. **先对屏幕整体截图，再按选区坐标裁剪**：`desktop_screenshot` 的 `getScreenshot()` 一般只返回主显示器的图像，因此裁剪坐标需相对主屏；多显示器场景下若选区落在副屏，需先按屏幕布局把全局坐标换算为主屏坐标，或改用支持多屏的 `screen_capturer`；
5. 裁剪结果保存 PNG 至 `getApplicationSupportDirectory()/screenshots/<时间戳>_<随机后缀>.png`；
6. 预览组件显示截图。

**平台权限：**

- macOS：必须在「系统设置 → 隐私与安全性 → 屏幕录制」中授权本应用，否则截图为黑屏/桌面壁纸。`macos/Runner/Info.plist` 需添加用途说明，Debug/Release entitlements 允许相应能力；
- Windows 11：一般无需额外授权。

### 4.5 操作防抖（风控）

- 同一按钮点击后至少间隔 300ms 才可再次触发（UI 层防抖）；
- 【AI 判分】、【DeepSeek 视觉重识别】在请求进行中禁用按钮，防止重复提交；
- 两次 DeepSeek API 调用之间建议间隔 ≥ 1s（独立于上面的按钮防抖，用于模拟人工节奏，降低外部风控误伤）。

## 5. 完整业务流程

1. 程序启动：初始化竖长侧边窗口（默认约 380×900，可调，置顶）；读取 SQLite 配置表，加载 DeepSeek API Key、PaddleOCR 程序路径、模型名；
2. 点击【框选截图】，框选阅卷网页上的学生答案区域，截图保存为本地 PNG，在界面预览图片；
3. 默认操作：点击【本地 OCR 识别】，调用本地 OCR 程序识别图片，识别全文填充【学生答案】；
4. 教师校对识别文字：
    - 识别效果良好：手动填写【标准答案】与【该题的总分】；
    - 识别文字错误较多：点击【DeepSeek 视觉重识别】，弹窗确认上传图片；确认后调用 `deepseek-flash` 识别，结果覆盖【学生答案】；
5. 点击【AI 判分】：读取界面当前的题目、学生答案、标准答案、总分，构造独立请求提交 DeepSeek 判分模型；返回 AI 分数，自动校验分数范围；UI 自动将`老师给的分数`赋值等于 AI 分数；
6. 教师按需修改【老师给的分数】；
7. 点击【保存本题】：写入 SQLite（含截图路径、识别来源、时间）；
8. 点击【下一题】：清空学生答案、AI 分数、教师分数与截图预览，无任何上一题上下文残留；**保留【标准答案】与【该题的总分】**（同一份试卷每题一致，一次录入即可复用）；若当前表单存在**未保存**的内容，先弹窗确认再清空，避免误丢数据；
9. 循环执行，逐题阅卷。

## 6. 异常、安全与风控要求

1. 仅做屏幕截图，不会向阅卷平台发起任何网络请求；
2. 图片上传完全可控，只有教师手动确认后，截图才上传 DeepSeek；本地 OCR 模式图片不出外网；
3. 网络检测：断网时【DeepSeek 视觉重识别】、【AI 判分】按钮置灰不可用；本地 OCR 不受网络影响；
4. API 请求增加超时处理，捕获网络异常、接口限流、模型返回格式错误等情况并弹窗提示；
5. 增加操作间隔限制，禁止高频连续点击，模拟人工操作，降低触发阅卷平台风控的概率；
6. AI 返回分数强制校验，限制在 0 至本题总分区间，保证数据合法；
7. API Key 仅存本地 SQLite，日志与错误弹窗中对 Key 做脱敏（只显示前 4 位 + `****`）；
8. 截图文件命名使用时间戳 + 随机后缀（用 `Random.secure()` 生成，而不是从时间戳派生），避免可预测路径被外部程序批量读取。

## 7. 运行环境与部署

### Windows 11

- 操作系统：Windows 11
- 前置依赖：本地 OCR 可执行程序（可自行准备 PaddleOCR 便携 exe 等，遵循 §4.3 协议），放置程序同级目录或自定义路径
- 屏幕截图：一般无需额外系统授权

### macOS

- 操作系统：macOS 12+
- 前置依赖：本地 OCR 可执行程序。仓库自带基于系统 Vision 框架的实现，运行 `bash tools/ocr_vision/build.sh` 生成 `tools/ocr_vision/bin/ocr_vision`（需 Xcode 或 Command Line Tools），再把该路径填到配置面板；也可改用 PaddleOCR 等其它实现（协议见 §4.3）。
- **必须授予「屏幕录制」权限**，否则区域截图失败
- **Sandbox 需关闭**：本应用要执行外部程序（PaddleOCR wrapper）并读取任意路径截图，macOS 的 App Sandbox 会阻止这些操作。因此 `macos/Runner/*.entitlements` 中不启用 `com.apple.security.app-sandbox`，仅保留网络客户端权限（`com.apple.security.network.client`）以便访问 DeepSeek API。
- Swift Package Manager 构建首次需要解析依赖，会写入 `~/Library/Developer/Xcode/DerivedData`，确保当前用户对该目录有写权限。
- **「自动阅卷」需额外授予「辅助功能（Accessibility）」权限**：在「系统设置 → 隐私与安全性 → 辅助功能」中勾选本应用，否则模拟点击/键盘会被系统丢弃。仅使用手动模式时不需要该权限。

>
> 首次启动软件后，需要在配置面板填写 DeepSeek API Key，设置 PaddleOCR 程序路径。

## 8. 项目目录结构

```
lib/
├── main.dart                      # 程序入口（window_manager 窗口初始化 + sqflite ffi）
├── ui/
│   ├── judge_main_page.dart       # 主竖长 UI 页面（自动化/截图/OCR/判分/保存交互）
│   ├── calibration_wizard_overlay.dart # 引导式标定：一次截图逐步点选/框选关键坐标
│   ├── point_picker_overlay.dart  # 全屏单击取点遮罩（单点重标定用）
│   └── region_select_overlay.dart # 全屏透明框选遮罩层
├── services/
│   ├── deepseek_client.dart       # DeepSeek HTTP 共用管道（鉴权、超时、错误归一化、日志）
│   ├── log_service.dart           # 内存日志（界面底部查看发给 AI 的内容）
│   ├── mac_input_service.dart     # 自动化：CoreGraphics CGEvent 模拟鼠标/键盘（macOS）
│   ├── paddle_ocr_service.dart    # 本地PaddleOCR服务（子进程协议 §4.3）
│   ├── deepseek_vl_service.dart   # deepseek-flash 视觉识别服务
│   ├── deepseek_judge_service.dart# DeepSeek 文本判分服务
│   ├── screenshot_service.dart    # 截图框选服务
│   ├── network_service.dart       # 网络状态检测
│   └── sqlite_service.dart        # SQLite数据库服务
├── models/
│   └── question_record.dart       # 题目实体模型
└── utils/
    └── validator.dart             # 分数校验、通用工具

tools/
└── ocr_vision/                    # 自带本地 OCR（Swift + macOS Vision）
    ├── main.swift                 # 源码
    ├── build.sh                   # 编译脚本
    └── bin/ocr_vision             # 编译产物（.gitignore，不入库）

# 运行时数据（不放进仓库）
<app_support>/screenshots/         # 截图 PNG 落盘目录
<app_support>/judge_assistant.db   # SQLite 数据库
```

>
> **实现状态：** 入口、主 UI 页面、框选遮罩层与 `lib/services/` 服务层均已实现，并已通过 `flutter analyze`、`flutter test` 与 `flutter build macos`。

>
> **注意：** 截图不写 `assets/`。Flutter `assets/` 在打包后只读，且会打进安装包。

## 9. 项目依赖 pubspec.yaml

```yaml
name: judge_assistant
description: 阅卷辅助小助手
version: 0.1.0
publish_to: 'none'

environment:
  sdk: '>=3.0.0 <4.0.0'
  flutter: '>=3.10.0'

dependencies:
  flutter:
    sdk: flutter
  window_manager: ^0.5.0
  screen_retriever: ^0.2.0
  desktop_screenshot: ^0.0.4
  sqflite_common_ffi: ^2.3.0
  path_provider: ^2.1.0
  path: ^1.9.0
  ffi: ^2.1.0
  http: ^1.2.1
  connectivity_plus: ^6.0.0
  image: ^4.2.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0

flutter:
  uses-material-design: true

# 使用操作系统自带 SQLite，避免 sqlite3 build hook 从 GitHub 下载预编译库
hooks:
  user_defines:
    sqlite3:
      source: system
```

>
> 版本号实现时以 `flutter pub get` 实际解析为准（`desktop_screenshot` 目前最新只到 `0.0.4`，**不存在 `1.x`**）；若 `desktop_screenshot` 无法满足区域截图（如多屏），可换 `screen_capturer` 等桌面截图库，遮罩框选层不变。
>
> `hooks.user_defines.sqlite3.source: system` 让 `sqlite3` 的 build hook 直接使用操作系统自带的 SQLite（macOS 的 `libsqlite3.dylib`），避免构建时从 GitHub 下载预编译动态库（受限网络下会失败）。若想改为自带 SQLite，可去掉该配置或改用 `source: source`。
>
> 已用 **Flutter 3.47.5 / Dart 3.13.4** 验证：`flutter analyze` 无问题、`flutter test` 全通过、`flutter build macos --debug` 可产出。

## 10. 限制说明

1. 截图区域只有学生作答内容（无题干），本地 OCR 输出连续文本后整体填入【学生答案】，识别有误可人工编辑（见 §3.3）；
2. 学生字迹极度潦草时，即使 DeepSeek 多模态识别，依然会出现识别错误，**必须人工校对**；
3. AI 给出的分数仅作为阅卷参考，不能替代教师阅卷，最终成绩由教师确认；
4. DeepSeek 相关功能依赖网络，断网无法使用，调用 API 会产生 token 费用；
5. 截图文件不会自动清理，可在配置面板提供「清理历史截图」按钮手动清空 screenshots 目录；
6. DeepSeek 模型名称与价格可能变动，实现时以 <https://api-docs.deepseek.com/> 最新文档为准，模型名放在配置表中以便热切换；
7. 自动阅卷的坐标标定与屏幕分辨率/缩放、显示器布局相关，更换显示器或调整缩放后需重新标定；
8. 自动填分/提交依赖**模拟鼠标键盘**操作浏览器，存在被阅卷系统风控误判的可能，请自行评估；本程序仍不访问阅卷系统接口、不读取其页面内容。
