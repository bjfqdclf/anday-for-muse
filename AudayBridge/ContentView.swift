import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var setupAlert = false
    @State private var audioAlert = false
    @State private var syncAlert = false
    @State private var retry = false
    @State private var day = Date()
    @State private var instruction = FileMuseBridge.defaultInstruction
    @State private var result = ""
    @State private var showPreview = false
    @State private var profileName = "default"
    private let labels = ["Skill 包", "基础环境", "语义搜索", "手机配对", "同步提交", "语义索引", "Muse 导出"]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) { Text("Auday Bridge").font(.largeTitle.bold()); Text(model.freshness).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Spacer()
                Button("刷新状态") { model.refresh() }.disabled(model.working)
            }
            HStack {
                ForEach(0..<labels.count, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(labels[i], systemImage: model.states[i] ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.states[i] ? .green : .secondary)
                        Text(model.states[i] ? "已验证" : "未就绪 / 待验证").font(.caption2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding().background(.quaternary.opacity(0.4)).cornerRadius(12)
            HStack {
                Button("准备环境") { setupAlert = true }
                Button("发现手机") { model.discover() }.disabled(!model.states[0])
                Menu("选择手机并配对") { ForEach(model.services, id: \.self) { service in Button(service) { model.pair(service) } } }.disabled(model.services.isEmpty)
                Button("同步") { retry = false; syncAlert = true }.disabled(!model.states[3])
                Button("建立索引") { model.index() }.disabled(!model.states[2] || !model.states[4])
                Button("导出") { model.export() }.disabled(!model.states[4])
                Spacer()
                Text("检查于 \(model.updatedAt)").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.working)
            HStack {
                Text(model.message).font(.callout).textSelection(.enabled)
                Spacer()
                if model.retryAvailable { Button("重试同步（一次）") { retry = true; syncAlert = true }.disabled(model.working) }
            }
            if model.resumableRecordCount > 0 {
                Label("发现 \(model.resumableRecordCount) 条可续传的大记录（已暂存 \(ByteCountFormatter.string(fromByteCount: model.resumableBytes, countStyle: .file))）；再次同步会从断点继续。", systemImage: "arrow.clockwise")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            TabView {
                browser.tabItem { Label("本地资料", systemImage: "books.vertical") }
                analysis.tabItem { Label("Muse 分析", systemImage: "sparkles") }
                connection.tabItem { Label("连接与转录", systemImage: "externaldrive.connected.to.line.below") }
            }
            ProgressPanel(runner: model.runner)
            if model.working { HStack { Text("正在运行；其余操作已禁用。").font(.caption); Spacer(); Button("取消当前操作", role: .destructive) { model.cancel() } } }
        }.padding(20)
        .task { model.refresh() }
        .sheet(isPresented: $showPreview) {
            VStack(alignment: .leading) {
                Text("将发送的来源 · " + model.dailyDate).font(.title2)
                ScrollView { Text(model.dailyRecords.map { record in
                    "来源：\(record.id) · \(record.kind) · \(record.start) \(record.timeZone) · \(record.status)\n\n" + record.text + "\n\n" + (model.derivatives[record.id] ?? "")
                }.joined(separator: "\n\n——\n\n")).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button("关闭") { showPreview = false }
            }.padding(24).frame(width: 800, height: 600)
        }
        .alert("准备本地语义环境", isPresented: $setupAlert) {
            Button("下载并准备") { model.prepare() }; Button("取消", role: .cancel) { }
        } message: { Text("模型 333.59 MB，Mac 运行时约 11.2 MB，另有基础运行时与解压空间。模型遵循 Gemma 条款（ai.google.dev/gemma/terms），在本机运行。") }
        .alert("同步前请确认", isPresented: $syncAlert) {
            Button(retry ? "重试一次" : "开始同步") { model.sync(retry: retry) }; Button("取消", role: .cancel) { }
        } message: { Text("• 手机与 Mac 在同一 Wi-Fi\n• Auday“接入你的工作流”页面保持前台\n• 手机保持亮屏并接电\n• 完成前不锁屏、不切换 App\n断开时本批不提交，暂存分块保留以便续传。") }
        .alert("准备本地转录", isPresented: $audioAlert) {
            Button("下载并验证") { model.setupAudio() }; Button("取消", role: .cancel) { }
        } message: { Text("\(model.audioModel == "small" ? "small 模型 190.09 MB" : "turbo 模型 574.04 MB")；Mac 运行时由 Apple 工具链构建。\(model.diarize ? "另含约 30 MB 匿名说话人模型及依赖。" : "不下载说话人权重。")产物新建，不覆盖原始音频或记录。") }
    }
    private var browser: some View {
        VStack {
            HStack {
                TextField("搜索内容", text: $model.query)
                Picker("模式", selection: $model.semantic) { Text("关键词（精确词）").tag(false); Text("语义（换说法）").tag(true) }.frame(width: 220)
                Picker("类型", selection: $model.kind) {
                    Text("全部").tag("")
                    ForEach(["transcript", "highlight", "summary", "reflection", "memory", "audio"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 170)
                TextField("日期 YYYY-MM-DD", text: $model.dateFilter).frame(width: 150)
                Button("查询") { model.browse() }
            }.disabled(model.working)
            HSplitView {
                VStack {
                    List(model.records) { record in
                        Button { model.read(record) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.title.isEmpty ? "无标题" : record.title).fontWeight(.medium)
                                Text("\(record.kind) · \(record.status)").font(.caption)
                                Text("\(record.start) \(record.timeZone)").font(.caption2).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                        }.buttonStyle(.plain).disabled(model.working)
                    }
                    HStack { Text("当前 \(model.records.count) 条 · \(model.semantic ? "语义匹配" : "关键词结果")").font(.caption); Spacer(); if model.nextOffset != nil && !model.semantic { Button("下一页") { model.browse(more: true) }.disabled(model.working) } }
                }.frame(minWidth: 300)
                ScrollView {
                    if let record = model.selected {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(record.title).font(.title2)
                            Text("来源 ID：\(record.id)\n类型：\(record.kind) · 状态：\(record.status)\n时间：\(record.start) · 时区：\(record.timeZone)").font(.caption).foregroundStyle(.secondary)
                            Text(record.text).frame(maxWidth: .infinity, alignment: .leading)
                            if !record.audioAssetIDs.isEmpty {
                                Text(model.audioAvailability(record))
                                HStack {
                                    Button("取回录音") { model.audio(record, transcribe: false) }
                                    Button("取回并本地转录") { model.audio(record, transcribe: true) }
                                }.disabled(model.working || !model.allowsAudio)
                                if !model.allowsAudio { Text("当前为仅文本授权；请在手机端改为文本与音频并重新同步。").font(.caption) }
                                if let transcript = model.derivatives[record.id] { Text(transcript) }
                            }
                        }.textSelection(.enabled).padding()
                    } else { Text("选择记录查看完整原文与来源信息").foregroundStyle(.secondary).padding() }
                }.frame(minWidth: 400)
            }
        }.padding(.top, 12)
    }
    private var analysis: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                DatePicker("分析日期", selection: $day, displayedComponents: .date)
                    .disabled(model.working)
                    .onChange(of: day) { _ in model.previewReady = false; model.dailyRecords = []; model.dailyDate = "" }
                Text("默认分析要求，可编辑").font(.caption)
                TextEditor(text: $instruction).frame(height: 115).border(.quaternary)
                HStack {
                    Button("汇总当日并准备缺失转录") {
                        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
                        model.prepareDay(formatter.string(from: day))
                    }
                    Button("发送给 Muse 分析") { model.sendDay(instruction: instruction) }.disabled(!model.previewReady)
                }.disabled(model.working)
                if model.currentAudioID != nil { Button("取消此录音，继续其余条目") { model.skipCurrentAudio() } }
                Text("\(model.dailyDate) · \(model.dailyRecords.count) 条 · 仅点击发送才生成请求").font(.caption)
                Text("日期未知或跨越多个来源日期的音频不会整段装入日报，以免混入其他日期的隐私内容。").font(.caption).foregroundStyle(.secondary)
                Button("查看完整待发送正文") { showPreview = true }.disabled(!model.previewReady)
                List(model.requests) { request in
                    Button { result = request.result ?? "尚未收到有效结果。请让已配对的 Muse 读取 requests 并按 MUSE-PROTOCOL.md 回写。" } label: {
                        VStack(alignment: .leading) { Text(request.id); Text(request.state.rawValue).font(.caption) }
                    }.buttonStyle(.plain)
                }
                Button("在 Finder 打开桥目录") { model.openExport() }
            }.padding().frame(minWidth: 430)
            ScrollView { MarkdownDocument(source: result.isEmpty ? "选择已完成请求阅读日报。文件桥不代表 Muse 在线；不会自动发送每日数据。" : result).padding() }.frame(minWidth: 380)
        }
    }
    private var connection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("关于 Muse 连接").font(.title2)
            Text("Muse 目前没有第三方应用可直接调用的公开接口。本应用使用文件桥：你明确发送后，Muse 通过已配对的 Mac 文件通道读取 requests，分析后在 results 回写。本应用不验证 Muse 在线状态，也不模拟点击或劫持粘贴。传给云端 Muse 的所选正文可能进入其云端模型；手机与 Mac 的同步及转录均在本地。")
            HStack {
                Text("独立手机 Profile：" + model.paths.profile)
                TextField("新 profile 名称", text: $profileName).frame(width: 180)
                Button("切换 / 新建 Profile") { model.switchProfile(profileName) }
            }
            Text("不同手机必须使用独立 profile；default 是 Muse 默认查找位置。").font(.caption)
            Text("本地转录设置").font(.title2)
            Picker("模型", selection: $model.audioModel) { Text("small · 190.09 MB · 轻量").tag("small"); Text("turbo · 574.04 MB · 质量优先").tag("turbo") }.frame(width: 430)
            Toggle("区分匿名说话人（不推断真实身份）", isOn: $model.diarize)
            Button("准备转录环境") { audioAlert = true }
            Link("Gemma 模型使用条款", destination: URL(string: "https://ai.google.dev/gemma/terms")!)
            Text("导出路径：\(model.paths.export.path)").font(.caption).textSelection(.enabled)
            Spacer()
        }.padding().disabled(model.working)
    }
}

private struct ProgressPanel: View {
    @ObservedObject var runner: CommandRunner
    var body: some View {
        VStack(alignment: .leading) {
            if let progress = runner.progress { ProgressView(value: progress) } else if runner.busy { ProgressView().controlSize(.small) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(runner.logs.enumerated()), id: \.offset) { index, line in Text(line).font(.system(.caption, design: .monospaced)).id(index) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 80).onChange(of: runner.logs.count) { _ in if !runner.logs.isEmpty { proxy.scrollTo(runner.logs.count - 1) } }
            }
        }.padding(10).background(.quaternary.opacity(0.25)).cornerRadius(8)
    }
}
