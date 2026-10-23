import Foundation
import Darwin

/// 单条代理分流聚合记录：按「目标（域名/IP）+ 是否直连」归并的流量。
struct ProxyRoutingEntry: Identifiable, Sendable {
    let id: String            // 分组键
    let target: String        // 域名或目标 IP
    let isDirect: Bool        // 命中 DIRECT 规则
    let chain: String         // 命中的代理链（直连时为 "DIRECT"）
    let rule: String          // 命中的规则类型
    let uploadBytes: Int64
    let downloadBytes: Int64

    var totalBytes: Int64 { uploadBytes + downloadBytes }
}

/// 一次分流快照。
struct ProxyRoutingSnapshot: Sendable {
    let isAvailable: Bool
    let errorMessage: String?
    let socketPath: String
    let uploadTotal: Int64
    let downloadTotal: Int64
    let entries: [ProxyRoutingEntry]
    let capturedAt: Date

    /// 当前活动连接的合计（与 entries 同量纲）。
    var totalBytes: Int64 {
        entries.reduce(0) { $0 + $1.totalBytes }
    }

    /// Clash 自启动以来的累计总量（与历史统计同量级，非活动连接）。
    var cumulativeBytes: Int64 { uploadTotal + downloadTotal }

    var directBytes: Int64 {
        entries.filter(\.isDirect).reduce(0) { $0 + $1.totalBytes }
    }
    var proxiedBytes: Int64 {
        entries.filter { !$0.isDirect }.reduce(0) { $0 + $1.totalBytes }
    }

    var uploadBytes: Int64 {
        entries.reduce(0) { $0 + $1.uploadBytes }
    }
    var downloadBytes: Int64 {
        entries.reduce(0) { $0 + $1.downloadBytes }
    }

    static func unavailable(_ message: String, socketPath: String) -> ProxyRoutingSnapshot {
        ProxyRoutingSnapshot(
            isAvailable: false,
            errorMessage: message,
            socketPath: socketPath,
            uploadTotal: 0,
            downloadTotal: 0,
            entries: [],
            capturedAt: Date()
        )
    }
}

/// 通过 Clash/mihomo 的外部控制接口（unix socket）读取 `/connections`，
/// 按「目标域名 + 是否直连」聚合实时流量，用于展示哪些目标走代理、哪些直连。
///
/// 说明：Clash 服务模式下的连接通常拿不到发起进程名（uid 恒为 0），
/// 因此这里以「域名/目标」为统计维度，而非进程。
final class ClashRoutingClient: @unchecked Sendable {

    /// 常见的 Clash Verge / mihomo unix socket 位置（按顺序探测）。
    static func candidateSocketPaths() -> [String] {
        let uid = getuid()
        return [
            "/var/run/clash-verge-service/users/\(uid)/verge-mihomo.sock",
            "/var/run/clash-verge-service/users/501/verge-mihomo.sock",
            "/tmp/verge-mihomo.sock"
        ]
    }

    private(set) var socketPath: String?

    init(socketPath: String? = nil) {
        self.socketPath = socketPath
    }

    /// 探测可用的 socket，返回成功路径。
    @discardableResult
    func probeSocket() -> String? {
        for path in Self.candidateSocketPaths() {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue
            else { continue }
            if (try? request(path: path, endpoint: "/version")) != nil {
                socketPath = path
                return path
            }
        }
        return nil
    }

    func fetchSnapshot() -> ProxyRoutingSnapshot {
        guard let path = socketPath ?? probeSocket() else {
            return .unavailable("未找到 Clash/mihomo 控制 socket，请确认 Clash Verge 正在运行。",
                                socketPath: "")
        }
        do {
            let data = try request(path: path, endpoint: "/connections")
            return Self.parse(data: data, socketPath: path)
        } catch {
            return .unavailable("读取 Clash 连接失败：\(error.localizedDescription)", socketPath: path)
        }
    }

    // MARK: - HTTP over unix socket（极简实现，避免引入依赖）

    /// 原始连接累计字节明细：connectionID -> (target, isDirect, 累计 up, 累计 down)。
    /// 供上层做「本次快照 - 上次快照」增量后写入历史库。
    struct RawConnection: Sendable {
        let id: String
        let target: String
        let isDirect: Bool
        let upload: Int64
        let download: Int64
    }

    func fetchRawConnections() -> [RawConnection]? {
        guard let path = socketPath ?? probeSocket() else { return nil }
        do {
            let data = try request(path: path, endpoint: "/connections")
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let connections = root["connections"] as? [[String: Any]]
            else { return [] }
            return connections.compactMap { conn in
                let metadata = conn["metadata"] as? [String: Any] ?? [:]
                let host = (metadata["host"] as? String)?.trimmingCharacters(in: .whitespaces)
                let destIP = metadata["destinationIP"] as? String
                let target = (host?.isEmpty == false ? host! : (destIP?.isEmpty == false ? destIP! : "未知目标"))
                guard let id = conn["id"] as? String else { return nil }
                let chains = conn["chains"] as? [String] ?? []
                let isDirect = chains.isEmpty || chains == ["DIRECT"]
                return RawConnection(
                    id: id,
                    target: target,
                    isDirect: isDirect,
                    upload: (conn["upload"] as? NSNumber)?.int64Value ?? 0,
                    download: (conn["download"] as? NSNumber)?.int64Value ?? 0
                )
            }
        } catch {
            return nil
        }
    }

    private func request(path: String, endpoint: String) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClashRoutingError.socketFailed(errno) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < maxLen else { throw ClashRoutingError.pathTooLong }
        withUnsafeMutablePointer(to: &addr.sun_path) { rawPtr in
            rawPtr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dest in
                for (i, b) in pathBytes.enumerated() { dest[i] = CChar(bitPattern: b) }
                dest[pathBytes.count] = 0
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw ClashRoutingError.connectFailed(errno) }

        let requestText = "GET \(endpoint) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        try writeAll(fd: fd, data: Array(requestText.utf8))

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                response.append(contentsOf: buffer[0..<n])
            } else {
                break
            }
        }
        return try Self.extractBody(from: response)
    }

    private func writeAll(fd: Int32, data: [UInt8]) throws {
        var offset = 0
        while offset < data.count {
            let n = data[offset...].withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress, data.count - offset)
            }
            if n <= 0 { throw ClashRoutingError.writeFailed(errno) }
            offset += n
        }
    }

    static func extractBody(from response: Data) throws -> Data {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = response.range(of: separator) else {
            throw ClashRoutingError.badResponse
        }
        var body = response.subdata(in: range.upperBound..<response.endIndex)

        // 处理 chunked 传输（mihomo 默认对 /connections 使用 chunked）。
        let headerText = String(decoding: response[..<range.lowerBound], as: UTF8.self).lowercased()
        if headerText.contains("transfer-encoding: chunked") {
            body = try dechunk(body)
        }
        return body
    }

    static func dechunk(_ data: Data) throws -> Data {
        var result = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while index < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { break }
            let sizeLine = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
            let sizeText = sizeLine.split(separator: ";").first.map(String.init) ?? sizeLine
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else {
                break
            }
            let chunkStart = lineEnd.upperBound
            let chunkEnd = chunkStart + size
            guard chunkEnd <= data.endIndex else { break }
            result.append(data[chunkStart..<chunkEnd])
            index = chunkEnd + crlf.count
        }
        return result.isEmpty ? data : result
    }

    // MARK: - 解析 /connections

    static func parse(data: Data, socketPath: String) -> ProxyRoutingSnapshot {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .unavailable("Clash 返回数据无法解析。", socketPath: socketPath)
        }
        let uploadTotal = (root["uploadTotal"] as? NSNumber)?.int64Value ?? 0
        let downloadTotal = (root["downloadTotal"] as? NSNumber)?.int64Value ?? 0
        let connections = root["connections"] as? [[String: Any]] ?? []

        struct Bucket { var up: Int64; var down: Int64; var chain: String; var rule: String; var direct: Bool }
        var buckets: [String: Bucket] = [:]

        for conn in connections {
            let metadata = conn["metadata"] as? [String: Any] ?? [:]
            let host = (metadata["host"] as? String)?.trimmingCharacters(in: .whitespaces)
            let destIP = metadata["destinationIP"] as? String
            let target = (host?.isEmpty == false ? host! : (destIP?.isEmpty == false ? destIP! : "未知目标"))

            let chains = conn["chains"] as? [String] ?? []
            let isDirect = chains.isEmpty || chains == ["DIRECT"]
            let chainLabel = isDirect ? "DIRECT" : chains.first ?? "代理"
            let rule = conn["rule"] as? String ?? ""

            let up = (conn["upload"] as? NSNumber)?.int64Value ?? 0
            let down = (conn["download"] as? NSNumber)?.int64Value ?? 0

            let key = "\(target)|\(isDirect)"
            if var existing = buckets[key] {
                existing.up += up
                existing.down += down
                if existing.chain.isEmpty { existing.chain = chainLabel }
                buckets[key] = existing
            } else {
                buckets[key] = Bucket(up: up, down: down, chain: chainLabel, rule: rule, direct: isDirect)
            }
        }

        let entries = buckets.map { key, value in
            ProxyRoutingEntry(
                id: key,
                target: key.split(separator: "|").first.map(String.init) ?? key,
                isDirect: value.direct,
                chain: value.chain,
                rule: value.rule,
                uploadBytes: value.up,
                downloadBytes: value.down
            )
        }.sorted { $0.totalBytes > $1.totalBytes }

        return ProxyRoutingSnapshot(
            isAvailable: true,
            errorMessage: nil,
            socketPath: socketPath,
            uploadTotal: uploadTotal,
            downloadTotal: downloadTotal,
            entries: entries,
            capturedAt: Date()
        )
    }
}

enum ClashRoutingError: LocalizedError {
    case socketFailed(Int32)
    case connectFailed(Int32)
    case writeFailed(Int32)
    case pathTooLong
    case badResponse

    var errorDescription: String? {
        switch self {
        case let .socketFailed(code): "创建 socket 失败（errno \(code)）"
        case let .connectFailed(code): "连接 socket 失败（errno \(code)）"
        case let .writeFailed(code): "写入 socket 失败（errno \(code)）"
        case .pathTooLong: "socket 路径过长"
        case .badResponse: "响应格式异常"
        }
    }
}
