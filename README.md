# Whisper

按住右 ⌘ 说话，松手出字。中文、英文、中英混说都行。

菜单栏常驻，没有 Dock 图标。转写走 OpenAI Realtime 的 `gpt-live-transcribe`，
说话过程中文字就会实时打进你正在输入的那个 App，松手后再自动整理掉口头禅。

## 怎么用

1. 按住 **右 Command** 超过 300ms → 屏幕底部的小条变宽 → 开始说话
2. 边说边有字出现在光标处
3. 松手 → 约 1.5 秒后文字自动整理（去掉「嗯、啊、那个」，补标点）

短按右 ⌘ 不会触发，它仍然是普通修饰键。按住期间再按别的键（比如 ⌘C）会自动取消录音。

## 设置

菜单栏图标 → 设置（⌘,）

设置 → **软件更新** 里的 **检查更新** 可以立即查找新版，结果会显示在当前版本旁边。
“自动更新”开启后会定期检查，并自动下载和安装新版本；默认关闭。

- **听写**：连接方式、触发键、转写模型、延迟、文字整理和常用词汇
- **设置**：登录启动、辅助功能 / 麦克风，以及当前连接方式使用的凭据

> 触发键里原来有 **Fn**，现在去掉了。之前选了 Fn 的机器升级后会**静默回落到右 Command**
> ——`UserDefaults` 里存的 `"fn"` 解析不出对应的枚举值，就走了默认值，App 不会提示。
> 如果你按住 Fn 发现没反应，去设置里重新挑一个键即可。

人名的处理分两层，都在整理这一步，所以要开着「自动去掉口头禅、补标点」才生效：

- **明显是英文名音译的，不用配置就会转成原名**：「凯文和艾米明天过来」→「Kevin 和 Amy
  明天过来」，「我跟莎拉聊过了」→「我跟 Sarah 聊过了」。中文名字（于诗禾、小明）、公司
  和机构名（阿里巴巴、斯坦福）、已有通行译名的公众人物（马斯克、特朗普）都不动，「麦克风」
  这种不是人名的音译也不动——这些都实测过。
- **「常用词汇」放模型猜不到的**：同事的名字、内部术语、项目代号。一行一个。实测写了
  `赵砚辞`，「赵言词老师」会修成「赵砚辞老师」；写了 `Xcode`，「我用 ex code 打开」会
  修成 Xcode。

没有单独的「出字方式」开关：选了 `gpt-live-transcribe` 就是边说边上屏，选了
`gpt-transcribe` 就是松手后上屏。这不是两个决定，是同一个。

## 结构

```
Whisper/
├── Core/
│   ├── AppSettings.swift          UserDefaults 支撑的设置
│   └── DictationController.swift  串起热键→录音→转写→整理→上屏的状态机
├── Input/
│   ├── HotKeyMonitor.swift        CGEventTap 长按检测（靠设备位区分左右修饰键）
│   ├── TextInjector.swift         合成键盘事件把字打进别的 App
│   └── Permissions.swift
└── UI/
    ├── RecordingHUD.swift         底部那根低调的小条
    ├── MenuBarView.swift
    └── SettingsView.swift
DictationKit/                    本地 SwiftPM 包，见下
server/                          可选的自托管 Relay（WebSocket 转写 + HTTPS 整理）
```

### DictationKit

录音、转写、整理、凭据这四块搬进了本地 SwiftPM 包，因为 [Wink](../Wink) 也要用。
复制一份会漂移，所以做成了一个包、两个 App 依赖它：

```
DictationKit/Sources/DictationKit/
├── AudioCapture.swift         采集 + 重采样到 24kHz PCM16 + 预卷缓冲
├── RealtimeClient.swift       常驻预热的转写 WebSocket
├── TranscriptPolisher.swift   松手后的文字整理
├── ServiceRoute.swift         直连 / 代理的路由快照
├── KeychainStore.swift        API Key 与设备 Token 存钥匙串
└── DictationEnvironment.swift 包向宿主索取设置的协议
```

**包的编译设置必须和 App target 一致，那不是偏好。** 这些文件是在
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`、语言模式 5 和一组 upcoming feature
下写的，少一个意思就变了——`NonisolatedNonsendingByDefault` 直接决定 nonisolated
async 函数跑在哪个 executor 上。`DictationKit/Package.swift` 里记了怎么从真实的
编译命令重新导出这份清单，App target 的设置改了就照着改。

**包不能反过来引用 App 的 `AppSettings`**，所以依赖方向反过来了：包用
`DictationSettingsProviding` 声明自己要什么，宿主在启动时注入。Whisper 注入
`AppSettings.shared`（在 `applicationDidFinishLaunching` 的第一行，且在 XCTest
的提前返回之前——测试会走到读它的 `ServiceRoute`）。忘了注入不会崩，会静默回落到
一份读同样 UserDefaults 键的兜底实现，所以别忘。

三个枚举（`ConnectionMode`、`TranscriptionModel`、`TranscriptionDelay`）跟着搬进了
包，因为对它们做事的是 `ServiceRoute` 和 `RealtimeClient`。留在 App 里的是
`displayName` / `summary` / `Identifiable`——包不该持有会本地化的界面文案。

## 代理模式（本机不放 OpenAI Key）

「听写」里可以手动选择两种连接方式：

- **直连**：保持原来的行为，Mac 用钥匙串中的 OpenAI API Key 直接请求 OpenAI。
- **代理模式**：走已经配置好的 `https://limingyi.com/whisper-relay`；Mac 只持有
  Keychain 中可撤销的设备 Token，OpenAI API Key 只存在服务器环境变量中。

  名字里没有「大陆」是有意的：它解决的是**本机不放 OpenAI Key**，无 VPN 可用只是
  其中一个后果。公开发行版第一次打开时用一次性邀请码激活，由 App 在本机生成独立的
  设备 Token 并存进 Keychain；服务端只保存 hash。这样每台 Mac 都能单独吊销，不需要
  把自己的 API Key 或某个大家共用的 Token 复制给别人——不管对方在哪个国家。

Relay 同时覆盖 Realtime WebSocket 转写和松手后的 HTTPS 整理。不能只代理整理请求，否则
Realtime 仍然需要从 Mac 直连 OpenAI。连接方式发生变化时，如果当前有一句正在转写，应用会等
它结束再重连，不会中途换线路或重放音频。

启动 Relay：

```bash
cd server
npm install
npm run generate-token
cp .env.example .env
# 编辑 .env：填 OPENAI_API_KEY，并把生成出来的 hash 填入
# RELAY_DEVICE_TOKEN_HASHES
npm test
npm start
```

`npm run generate-token` 打印一对值：**设备 Token** 粘贴到 App 的「设置 → 代理」
（切到代理模式后才会出现），服务器只保存它的 **SHA-256 hash**。Token 只在生成时
显示一次。凭据由 App 自己写进钥匙串，不要用 `security` 命令行塞进去——那样建出来的条目 ACL
里没有本 App，读取时会弹授权框甚至直接失败。

### 发行、邀请与吊销

线上部署由 `script/deploy_relay.sh` 设置了 `RELAY_DEVICE_TOKEN_FILE`，**一旦设了这个变量，
`RELAY_DEVICE_TOKEN_HASHES` 就完全被忽略**。所以不要去改环境变量里的 hash：服务会正常启动，
但旧版个性化包的 Token 依然在文件名单里有效。

新的主流程是一份通用 DMG，加每人一个一次性邀请码：

```bash
./script/package_release.sh --public      # 生成、公证并验证 dist/Whisper-public.dmg
./script/invite_access.sh alice            # 单独生成 alice 的一次性邀请码
./script/invite_access.sh --list           # 看待激活、有效和已吊销的身份
./script/invite_access.sh --revoke alice   # 立即吊销 alice
```

通用版从 1.1 开始内置 Sparkle 2 更新。完整发布统一使用：

```bash
./script/bump_update_version.sh                       # 自动准备下一个版本号 / build
./script/publish_update.sh path/to/release-notes.md   # release notes 可省略
```

脚本要求改动已审查、测试、提交且工作树干净；它会 push 源码，生成已签名公证的通用 DMG，
创建 GitHub Release，验证下载地址，最后才提交并 push EdDSA 签名的 appcast。脚本用 GitHub
Contents API 校验刚推送的精确 commit，并等待 raw feed 在 5 分钟 CDN TTL 内刷新；若 CDN 仍旧
缓存旧内容，脚本会在权威校验成功后给出警告，而不会误报发布失败。详细的代理行为、版本要求与
恢复见 `RELEASING.md`。Sparkle 私钥只保存在发行 Mac 的 Keychain；仓库和 App 内只有公钥。

DMG 可以原样发给所有人，包内没有设备 Token。邀请码只显示一次；同一个邀请码只允许第一台
设备认领，但第一台设备在服务器已提交、响应却丢失时可以用本机尚未提交的 Keychain Token
安全重试。签发、查询和吊销只经过 mode 0600 的本机 Unix admin socket，公网不暴露管理接口。

`--for alice` 的旧个性化 ZIP 流程仍保留作兼容路径；它把独立 Token 烘进该收件人的包，且只在
构建、公证和检查全部通过后注册：

```bash
./script/package_release.sh --for alice
./script/revoke_token.sh                  # 查看旧个性化 Token
./script/revoke_token.sh alice            # 吊销旧个性化 Token
```

旧名单变更走 `systemctl reload`（SIGHUP），邀请身份由正在运行的 Relay 原子写入 registry；两条
路径都**不重启**服务。吊销还会顺带断掉对方已经建立的连接，而其他人的 WebSocket 保持不动。

手工改 `/opt/whisper-relay/device-tokens` 也可以（一行一个 hash，支持 `hash # 备注`），改完
`systemctl reload whisper-relay`。名单解析失败时会保留旧名单而不是清空，所以写坏一个文件不会
把所有人锁在外面。

代价是「reload 看起来成功了」和「真的生效了」不是一回事：被拒绝的 reload 保留旧名单，而旧名单
的条数完全可能和新文件相同。所以 `/healthz` 除了 `tokens` 还返回 `allowlist`——当前生效名单的
指纹，两个脚本都拿自己刚写的文件算同一个指纹去比对，对不上就回滚。手工改完想确认，同样看它变了
没有。

### 反向代理

Relay 自己监听 `/v1/realtime`、`/v1/polish`、`/v1/enroll` 和 `/healthz`。线上发布在
`https://limingyi.com/whisper-relay` 这样的子路径下时，把 `RELAY_BASE_PATH=/whisper-relay`
写进 `.env`：这样带不带前缀的路径它都认，代理是否剥掉前缀都能工作（少了这一条，代理配错
斜杠的表现是一个干净的 404，日志里什么都没有）。

代理还必须支持 WebSocket upgrade、至少 2 MiB 的消息，并且不能移除客户端的 `Authorization`
header。`GET /healthz`（或 `<前缀>/healthz`）可用于健康检查；发行脚本还会向公网
`/v1/enroll` 发送一个故意无效的 JSON，并断言收到 Relay 的 400 错误，避免只通 health、实际
激活路径却被 nginx 或 edge 漏配。管理 socket `/run/whisper-relay/admin.sock` 只能留在服务器
本机，不能代理到公网。

默认 `HOST=127.0.0.1`，因为没挂代理时不该把一个背后是真 OpenAI Key 的端点暴露到所有网卡上；
`server/Dockerfile` 里已经显式设成 `0.0.0.0`，由前置负载均衡或反向代理终止 TLS。

### 边界与自查

Relay 只允许本 App 使用的三个转写模型、固定整理模型和有限的请求形状；另外限制每设备并发、
单轮音频大小和整理频率。上限不是随手取的整数，是按 App 自己那 610 秒音频缓冲推出来的——改
客户端缓冲时对应改 `CLIENT_MAX_TURN_AUDIO_BYTES`。上行拥塞时 Relay 会暂停读取来施加背压，
而不是掐断连接，否则丢掉的正是排队补录机制要保住的那句话。Relay 每 25 秒 ping 一次 Mac，
一整个周期没有 pong 就断开：合盖和换 Wi-Fi 都会留下半开连接，不清掉的话它既占着设备的并发
名额，也让那条计费的 OpenAI session 一直活着。

不要记录请求体或 Authorization header，并为服务器上的 OpenAI key 单独设置预算。部署完成后
仍要在无 VPN 的不同网络上实测域名、TLS 和 WebSocket 长连接是否可达。

想指向本地 Relay 调试（生产地址是写死的，设置里不给改）：

```bash
defaults write com.mingyili.Whisper relayBaseURLOverride http://localhost:8787
defaults delete com.mingyili.Whisper relayBaseURLOverride
```

只接受 HTTPS，或指向 loopback 的 HTTP；值不合法就静默回落到生产地址。

## 几个不那么显然的设计

**连接必须常驻。** 建连到 session 可用要约 2 秒，按下热键才连必然吞掉开头。所以
socket 在 App 启动时就建好、用 ping 保活、会话快过期时提前换新。万一按下时还没连上，
音频会先在本地缓冲，连上后补发——不会丢字，只是晚到。

**按下就开始收音。** 长按阈值内的声音存进 1 秒预卷缓冲，确认是长按后连同这段一起发出去，
所以不会吃掉第一个字。

**注入文字时要清空修饰键。** 录音时右 ⌘ 是按住状态，直接合成按键会变成 ⌘N 之类的快捷键。
解决办法是用 `.privateState` 的事件源 + 显式把 `flags` 清零。万一某个 App 里表现异常，
设置里可以切成「松手后一次性粘贴」。

**沙盒必须关。** CGEventTap 和合成键盘事件在 App Sandbox 里都用不了。Hardened runtime
保持开启，麦克风靠 `com.apple.security.device.audio-input` entitlement。

**换便宜模型就换不来实时上屏。** 实测同一段音频：`gpt-live-transcribe` 在 commit 前发出
20 个 delta，`gpt-transcribe` 是 **0 个**。注意不能看 delta 总数——两者总数几乎一样
（23 vs 24），差别全在时间上：便宜那档把每一个 delta 都堆到 commit 之后才发，那时人已经
松手了。所以出字方式不是一个独立选项，而是模型能力的直接结果。
（`script/ab_transcribe.mjs` 可以随时重测这组数。）

**事件要按 `item_id` 认领，不能靠先来后到。** 跨轮次的完成事件顺序没有保证，而
`input_audio_buffer.committed` 会返回本轮权威的 `item_id`。仅用「第一个转写事件」认领
是不够的：上一轮超时取消后，它的迟到事件可能抢在新一轮前面到达、把自己的 id 认领成新一轮
的 id，于是旧句子结束了新录音，真正的新结果反被丢弃。所以放弃的轮次会进 retired 名单。

**转写和整理必须分开做。** 非 realtime 模型确实支持 `prompt` 参数，看起来可以让它
"边转写边整理"。实测不行：同一段音频、同一个模型，唯一变量是加不加整理 prompt，加了之后
`deadline`→`dead line`、`backend`→`button`、`Kevin`→`Kelvin`，而且口头禅还没删干净
（gpt-4o-mini-transcribe 更是完全无视）。`prompt` 在 Whisper 系列里是词汇/风格偏置，
不是指令通道，拿它当指令用会让模型分心，两件事都做不好。

**常用词汇现在两边都挂。** 上一代的 `gpt-realtime-whisper` 直接拒收 `prompt`，而它是唯一
能边说边出字的模型，词表就只剩整理模型这一条路。新一代多了专门喂术语的 `keywords`，这个
限制没有了。实测同一段音频、唯一变量是这个字段：不加是「李**明**一」「赵**云熙**」，加了是
「李**铭**一」「赵**芸溪**」，首字延迟没变化。

注意这**不是把职责搬过去了**，是加了一道。整理那侧的词表留着，因为 keywords 是概率偏置不是
保证；而且只在用户真填了词的时候才追加那一段，空表时提示词与调优时逐字一致。上面那条「转写
和整理必须分开」依然成立——它说的是 `prompt` 当指令通道，和 `keywords` 是两套机制。

**词表的校验规则比看起来重要。** 它以前只喂整理模型，一条烂词最多少修一个字；现在它进了
`session.update`，一条烂词会让整个会话建不起来，口述直接不能用。所以长度按 **UTF-16** 计
（relay 是 JS，`"𠮷".length` 是 2 而 Swift 的 `count` 是 1，两边尺子必须一样），并且拒收
`<` `>`（API 不收，而且整理那侧正好用 `<transcript>` 包正文）。App 过滤一遍，relay 再独立
校验一遍——relay 不能信客户端的自觉，否则 `keywords` 就是一条通往 OpenAI 的自由文本通道。

**词表必须放宽 `isPlausible` 的长度上界。** 整理通常只会让文本变短，所以有个 1.6 倍的
上界防止模型"回答"而不是"整理"。但词汇替换是唯一会变长的整理：「凯文和艾米」(5 字) →
「Kevin 和 Amy」(11 字) 是 2.2 倍，会被判成模型跑偏而整句丢弃，用户反而拿回错的名字。
所以结果里每出现一个表内词，就按它自身长度放宽一点——余量由**实际返回的内容**决定，
而不是由词表长度决定，这样堆一百个词也无法悄悄把这道闸门废掉。

**「不要动人名」那条规则已经删掉。** 它和词表功能直接冲突（表里的词就是"该动"的依据）。
删之前对照实测过 8 句含专有名词 / 代码标识符的转写，6 句输出完全一致，一句变好
（"usr underscore idx" → `usr_idx`），没有出现乱改专有名词的情况。

**开头几个字的语言识别错，用 `delay` 调。** 流式模型必须在听完整句之前就吐字，开头
天然缺上下文。`delay` 就是控制吐字前先听多久的旋钮，实测首字返回时间：minimal 737ms、
low 811ms、medium 1250ms、high 1937ms。设置里叫「出字前先听多久」。

**改写已上屏的文字前必须确认光标还在原处。** 整理是异步的，那 1.5 秒里用户可能已经点了
别处、继续打字或切了 App。此时再按「删 N 个字符」去重写，删掉的就是别人的文字。所以松手
时会记录当时的前台 App 和最后一次真实用户输入的时间戳，两者任一变了就放弃重写、保留未整理
的版本。（我们自己注入的按键带标记，不会误判成用户输入。）

**别为了空格重打整句。** 键盘事件只能从光标往前删，所以任何差异都要求把它之后的内容
全部重打——差异出现在句首就等于整句重写，看起来就是"闪一下"。而 realtime 模型会在中文
句号后面加个空格、整理模型又会把它去掉，正好制造句首差异。所以纯空格差异直接跳过不改。

**整理模型固定为 gpt-5.6-terra，不暴露选项。** 8 轮交替实测过一批候选（gpt-5.4-mini
中位 1.68s 但出现过 4.70s；gpt-5.6 系列中位都在 1.7s 上下、尾部收敛），档位之间的差距
在噪音以内，不值得一个设置项，最终按质量档位定为 terra 并写死。

## 已知边界（有意的取舍，不是待修 bug）

往任意第三方 App 注入文字这件事在 macOS 上没有协议级确认：⌘V 没有回执，Electron 不暴露
AX ranges，焦点和键入无法原子绑定。以下取舍是审查后有意保留的，再次 review 时请先对照
这份清单：

**无 AX ranges 的控件里，重写仍会盲退格。** 光标守卫有三层：前台 App + 真实输入时间戳、
焦点元素同一性（抓程序性换输入框）、AX 文本比对（能读到 ranges 时要求逐字符匹配才删）。
剩下的洞是"同一元素内、程序性移动光标、且控件不暴露 ranges"——此时没有任何可观测量能发现
光标动了。唯一的"修法"是对所有 Electron 目标禁用原地修正，代价是最常见的目标从"自动改好"
退化成"每句留着口头禅 + 剪贴板兜底"，比它防的那个罕见场景伤害大得多。删除范围有界（只删
本次注入的字符数），可用 ⌘Z 恢复。

**连续 paste 合并只验证到元素级，不验证 caret。** 合并时刻"前一个 ⌘V 已被消费、caret
前进了"和"⌘V 还在队列里、caret 原地"都是合法状态，单次快照无法区分用户是否手动挪过光标，
caret 级检查必然产生假阴性。丢句风险由超时路径兜底：目标进程响应正常时，未确认的后续句子
会放上剪贴板。

**"目标是否卡死"是启发式判断。** 依据是 AX 请求由目标主 runloop 服务——能应答说明先于
探针送达的 ⌘V 几乎必然已出队。这是普遍但非契约的系统行为。

**停滞检测假设 75 KB/s 的最低健康上传。** 每个音频块被传输层接收都会续命计时器，所以更慢
但仍在动的链路不会被误杀；只有零进展超过窗口才判死。内核缓冲会让接收确认成簇到达，极端慢
链路上簇间隙理论上可能逼近窗口。

**路由配置断了的时候，已排队但还没转写的句子会丢。** 排队里存的是冻结的 PCM，没有转写文本，
所以在"凭据没配"这种状态下它既送不出去、也没有东西能退到剪贴板——留着也只是等一个永远不会
到来的重试。现在的做法是**在出队之前**先探一次路由：探失败就一次性清空整个队列、只报一条
错（并说明丢了几句），而不是逐句出队、逐句销毁音频、逐句弹同一条错误提示。

**整理挂掉时会提示一次，但不影响出字。** 整理失败一律回退到原始转写，文字照常上屏——
但如果失败原因是**会一直失败**的那种（API Key 无效、额度不足、地区被拒），静默就等于每句
话都白白失去整理而屏幕上毫无线索。所以这类原因会在文字落地**之后**弹一次提示条（不是错误
路径，句子已经交付了），同一个原因不重复弹，下次整理成功就清空标记。超时、5xx、限流这类
瞬时失败继续静默。

真实踩过的一个例子：路由器上的代理只接管 TCP，URLSession 把整理请求升级到 HTTP/3 之后走
UDP 直连，从家宽真实 IP 出去被 OpenAI 按地区拒（`unsupported_country_region_territory`），
而转写用的 `wss://` 是 TCP、一切正常。同一个 host、同一个 key，只有传输协议不同。没有公开
API 能禁掉 HTTP/3（`assumesHTTP3Capable` 只能强制开），所以这属于网络侧要解决的问题——
在路由器上丢弃出站 UDP 443 即可，QUIC 握手失败会立刻回落 TCP。

**一切丢字路径的最终兜底是历史记录。** 菜单栏「最近转写」保留最近 50 句，任何注入/粘贴
失败都可以从那里手动找回。

## 构建

```bash
xcodebuild -project Whisper.xcodeproj -scheme Whisper -configuration Debug -destination 'platform=macOS' build
```

首次运行需要授予**辅助功能**和**麦克风**权限。权限跟签名与路径绑定，建议固定装在
`/Applications/Whisper.app`，换位置要重新授权。
