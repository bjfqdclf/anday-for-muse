import Foundation

struct BridgePaths {
    let root: URL
    let skill: URL
    let profile: String
    let export: URL
    var profileDirectory: URL { root.appendingPathComponent(profile, isDirectory: true) }
    var bootstrap: URL { skill.appendingPathComponent("scripts/bootstrap.sh") }

    init(root: URL? = nil, skill: URL? = nil, profile: String = "default", export: URL? = nil) {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.root = root ?? support.appendingPathComponent("AudayWorkflow", isDirectory: true)
        self.skill = skill ?? support.appendingPathComponent("AudayBridge/auday-skill", isDirectory: true)
        self.profile = profile
        self.export = export ?? self.root.appendingPathComponent(profile + "/export", isDirectory: true)
    }
}

struct Record: Identifiable {
    let raw: [String: Any]
    var id: String { raw["id"] as? String ?? "" }
    var title: String { raw["title"] as? String ?? "无标题" }
    var kind: String { raw["kind"] as? String ?? "unknown" }
    var text: String { raw["text"] as? String ?? "" }
    var start: String { raw["start"] as? String ?? "" }
    var timeZone: String { raw["timeZone"] as? String ?? "" }
    var status: String { raw["state"] as? String ?? raw["status"] as? String ?? "未提供" }
    var audioAssetID: String? { raw["audioAssetID"] as? String }
}

struct BridgeError: LocalizedError {
    let code: String
    let message: String
    init(_ code: String, message: String? = nil) {
        self.code = code
        self.message = message ?? Self.messages[code] ?? "操作未完成。请运行环境诊断，检查环境与手机连接后重试。"
    }
    var errorDescription: String? { message }
    private static let messages = [
        "busy": "另一项操作正在运行，请等待或取消。",
        "cancelled": "已取消。本次操作不视为已完成，旧的完整缓存仍可使用。",
        "invalid_result": "工具没有返回有效结果，不能确认操作成功。",
        "not_paired": "请先发现并配对手机。",
        "awaiting_phone_or_wrong_password": "请打开手机的接入页面，检查同一 Wi-Fi 与本地窗口中的密码。",
        "connection_closed": "手机连接中断，本批未提交。暂存分块保留，可在保持手机亮屏、前台并接电后重试一次。",
        "snapshot_changed": "手机快照已变化，本批未提交，请重新同步一次。",
        "snapshot_busy": "手机正在处理其他传输，请等待结束后重试一次。",
        "snapshot_preparation_failed": "手机准备快照失败，请保持接入页面打开，查看手机提示后重试一次。",
        "snapshot_preparation_timed_out": "手机准备快照超时，请保持接入页面打开，查看手机提示后重试一次。",
        "record_chunk_hash_mismatch": "数据分块校验失败，旧缓存未被替换，请重试同步一次。",
        "record_hash_mismatch": "记录校验失败，旧缓存未被替换，请重试同步一次。",
        "source_device_changed": "来源设备已改变，请为新手机建立独立 profile，不能混入当前资料库。",
        "audio_access_denied": "当前手机只允许读取文本。需要录音时，请在手机端修改授权范围。",
        "semantic_library_not_synced": "请先完成同步，再建立语义索引。",
        "macOS_required": "此功能需要 macOS 环境，请运行环境诊断。"
    ]
}
