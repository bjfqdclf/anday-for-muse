# Auday Bridge

macOS 13+ SwiftUI 本地应用，把 Auday iPhone 只读缓存、语义检索、本地录音转写与 Muse 文件桥放在一个窗口。无第三方 Swift 依赖，不需要 Homebrew 或 git-lfs。语义运行时需要 macOS 13.3+；发现手机及构建音频运行时需要可用的 Apple 开发工具。

## 构建

使用 Xcode 16+ 打开 `AudayBridge.xcodeproj`，选择 `AudayBridge` scheme 后运行。工程关闭 App Sandbox，包含局域网用途说明。

```sh
xcodebuild -project AudayBridge.xcodeproj -scheme AudayBridge -configuration Debug -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
swift test
```

未签名开发构建位于 `build/Build/Products/Debug/AudayBridge.app`。本工程用于本机自用；开发构建不代表通过 Developer ID 签名、公证或可公开分发。

## 首次使用

1. 点击「准备环境」，在应用提示中核对下载量和 Gemma 条款后继续。应用下载固定 Auday 0.6.0 源码包，校验 SHA-256 与必要文件，再通过官方 bootstrap 准备运行时、模型及合成验证。
2. iPhone 与 Mac 连接同一 Wi-Fi，在 Auday 打开「接入你的工作流」，允许本地网络访问。点击「发现并配对手机」，选择自己的服务。通信密码只在 Auday 自带的本地窗口输入，应用没有密码输入框。
3. 手机接电、亮屏，保持该页面前台，执行同步。当前同步固定一个快照；中断不会替换旧库，暂存分块保留供一次显式重试。
4. 建立索引并导出。浏览页提供类型、来源日期、关键词或语义检索与完整详情。页面展示本地缓存及同步/快照时间。
5. 录音分析先在界面选择 small（190.09 MB）或 turbo（574.04 MB）；默认另需约 30 MB 匿名说话人模型。选择不区分说话人时，准备与转写均跳过该阶段。原记录与原音频不被覆盖。
6. 在 Muse 分析页选日期、检查正文与要求，点击发送才创建请求。Muse 通过已配对 Mac 的文件通道读取请求并回写结果；刷新后在应用读取完整结果。应用不会通过模拟点击伪装连接，也没有 Muse API 凭证。

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
