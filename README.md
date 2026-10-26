# Auday Bridge

macOS 13+ SwiftUI 本地应用，把 Auday iPhone 只读缓存、语义检索、本地录音转写与 Muse 文件桥放在一个窗口。无第三方 Swift 依赖，不需要 Homebrew 或 git-lfs。语义运行时需要 macOS 13.3+；发现手机及构建音频运行时需要可用的 Apple 开发工具。

## 构建

使用 Xcode 16+ 打开 `AudayBridge.xcodeproj`，选择 `AudayBridge` scheme 后运行。工程关闭 App Sandbox，包含局域网用途说明。

```sh
xcodebuild -project AudayBridge.xcodeproj -scheme AudayBridge -configuration Debug -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
swift test
```

未签名开发构建位于 `build/Build/Products/Debug/AudayBridge.app`。本工程用于本机自用；开发构建不代表通过 Developer ID 签名、公证或可公开分发。

## 下载与启动

- [下载最新版本](https://github.com/bjfqdclf/anday-for-muse/releases/latest)。打开 DMG，将 `AudayBridge.app` 拖到“应用程序”，然后从“应用程序”启动。
- 从源码运行：用 Xcode 打开 `AudayBridge.xcodeproj`，选择 `AudayBridge` scheme 和 `My Mac`，按 **⌘R**。不要仅打开项目目录中的 `Package.swift`；它只构建核心库，不会启动 macOS 应用。

## 使用方法

### 首次准备、发现手机与配对

1. 点击「准备环境」，在应用提示中核对下载量和 Gemma 条款后继续。应用下载固定 Auday 0.6.0 源码包，校验 SHA-256 与必要文件，再通过官方 bootstrap 准备运行时、模型及合成验证。
2. iPhone 与 Mac 连接同一 Wi-Fi，在 Auday 打开「接入你的工作流」，允许本地网络访问。点击「发现并配对手机」，选择自己的服务。通信密码只在 Auday 自带的本地窗口输入，应用没有密码输入框。
3. 手机接电、亮屏，保持 Auday 接入页面在前台，然后点击「同步」。同步使用固定快照；只有成功校验后才提交新缓存。

### 后续同步与断点续传

1. 每次同步前，让 iPhone 保持接电、亮屏，并停留在 Auday 的接入页面。
2. 如果连接中断，本批不会提交，旧缓存仍可用。大记录的已接收分块会保留在本机；重新同步会从暂存偏移继续，不必从头传完该记录。界面会显示可续传记录数和暂存容量，失败后也可点击「重试同步（一次）」。
3. 同步完成后会更新本地缓存和可读导出。若语义环境已准备好，应用也会更新索引；否则先完成环境准备，再点击「建立索引」。

### 浏览、检索与导出

- 在「本地资料」页输入关键词，选择「关键词（精确词）」或「语义（换说法）」，并可按类型和来源日期筛选；点击「查询」查看结果，选择一条记录可阅读完整原文。关键词结果可用「下一页」继续浏览。
- 语义检索需要先「准备环境」并完成同步。同步后如索引未就绪，点击「建立索引」；状态栏显示同步时间和来源快照时间。
- 点击「导出」可重新发布可读文件。默认目录是 `~/Library/Application Support/AudayWorkflow/default/export/`，也可在 Muse 分析页点击「在 Finder 打开桥目录」。

### 取回录音与本地转写

1. 在「连接与转录」页点击「准备转录环境」，选择 small（190.09 MB）或 turbo（574.04 MB），确认下载后等待校验完成。默认还会准备约 30 MB 的匿名说话人模型；关闭「区分匿名说话人」即可跳过。
2. 只有手机授权包含音频读取时，记录详情才可使用「取回录音」或「取回并本地转录」。文本授权不包含录音；需要录音时请先在手机端调整授权后重新同步。
3. 转录结果作为衍生文件保存，不覆盖原记录或原始音频。匿名说话人标签不代表真实身份。

### 准备日报并发送给 Muse

1. 在「Muse 分析」页选择日期，点击「汇总当日并准备缺失转录」。
2. 查看日期、记录数量和正文；需要时点击「查看完整待发送正文」，并编辑分析要求。
3. 确认内容后点击「发送给 Muse 分析」。只有这一步会创建文件桥请求；Muse 需要通过已配对的 Mac 文件通道读取请求并写回结果。
4. 点击「刷新状态」，再选择已完成请求阅读结果。请求显示「待处理」只表示文件已写入本机，不表示 Muse 已在线或已处理；应用不会自动重复发送。

Muse 没有可供本应用直接调用的公开接口。应用不会通过模拟点击伪装连接，也没有 Muse API 凭证。请求与结果格式见 `MUSE-PROTOCOL.md`。

## 文件与隐私

- 官方 Skill：`~/Library/Application Support/AudayBridge/auday-skill`
- 默认缓存：`~/Library/Application Support/AudayWorkflow/default/`
- 默认 Muse 桥：`~/Library/Application Support/AudayWorkflow/default/export/`
- 导出和衍生文件保留完整原文、来源与时间信息，仅供当前用户访问。不要将隐私缓存或导出目录加入源码版本控制或默认云同步目录。
- 应用日志仅展示阶段和计量值；记录原文只显示在浏览/分析正文中。
- Muse 没有可供本应用直接调用的公开接口。文件请求处于「待处理」仅说明已写入本地桥，不能证明 Muse 已读取。Muse 会话处理约定见 `MUSE-PROTOCOL.md`。

## 上游固定版本

Auday MIT 项目：<https://github.com/666ghj/auday-skill>。规范对应的版本 0.6.0 没有 `v0.6.0` tag；本应用固定官方提交 `20245721d7b60b8ac91cd68d2600c76b67348249`，源码 ZIP SHA-256 为 `4274d430902983b1170ae5e860a6817f320151d25cb99237e386db507f82e63e`。更新版本前应重新核对命令契约和哈希。

## 验证边界

自动测试使用合成记录与私有临时目录验证桥格式、筛选、原子发布、结果读取与安装完整性。编译通过不能代替真实 iPhone 配对、长同步断点续传、真实模型命中与音频质量验证；这些需要有权限的手机和真实运行时。Muse 实际回写需要已与 Mac 配对的 Muse 会话主动处理请求。未完成这些步骤时，不应把七项状态或端到端验收标成成功。

固定导出目录使用 `muse-status.json` 作为发布完成标记：更新时先移走旧标记，发布 index、days 和 manifest，最后原子放入新标记。读取端若标记不存在，应等待后重试；跨文件读取前后应核对标记未变化。发布异常会恢复上一完整快照；如果恢复本身失败，应用会保留私有备份并明确报告位置，不将混合快照标记为已完成。requests 与 results 不参与导出替换。
