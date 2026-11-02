import Foundation

/// `mo status --json` / `--watch` snapshot. Every field is optional so a CLI
/// update that drops or adds a field never breaks decoding.
struct StatusSnapshot: Decodable {
    struct Hardware: Decodable {
        var model: String?
        var cpuModel: String?
        var totalRam: String?
        var diskSize: String?
        var osVersion: String?
    }

    struct CPU: Decodable {
        var usage: Double?
        var perCore: [Double]?
        var load1: Double?
        var load5: Double?
        var load15: Double?
        var coreCount: Int?
        var logicalCpu: Int?
        var pCoreCount: Int?
        var eCoreCount: Int?
    }

    struct GPU: Decodable {
        var name: String?
        var usage: Double?
        var coreCount: Int?
    }

    struct Memory: Decodable {
        var used: Double?
        var total: Double?
        var available: Double?
        var usedPercent: Double?
        var swapUsed: Double?
        var swapTotal: Double?
        var cached: Double?
        var pressure: String?
    }

    struct Disk: Decodable {
        var mount: String?
        var used: Double?
        var total: Double?
        var usedPercent: Double?
        var external: Bool?
        var purgeable: Double?
    }

    struct DiskIO: Decodable {
        var readRate: Double?
        var writeRate: Double?
    }

    struct Network: Decodable {
        var name: String?
        var rxRateMbs: Double?
        var txRateMbs: Double?
        var ip: String?
    }

    struct NetworkHistory: Decodable {
        var rxHistory: [Double]?
        var txHistory: [Double]?
    }

    struct Battery: Decodable {
        var percent: Double?
        var status: String?
        var timeLeft: String?
        var health: String?
        var cycleCount: Int?
        var capacity: Double?
    }

    struct Thermal: Decodable {
        var cpuTemp: Double?
        var gpuTemp: Double?
        var batteryTemp: Double?
        var fanSpeed: Double?
        var fanCount: Int?
        var systemPower: Double?
        var batteryPower: Double?
    }

    struct Process: Decodable, Identifiable {
        var pid: Int32
        var ppid: Int32?
        var name: String?
        var command: String?
        var cpu: Double?
        var memory: Double?
        var memoryBytes: Double?
        var id: Int32 { pid }
    }

    struct Bluetooth: Decodable {
        var name: String?
        var connected: Bool?
        var battery: String?
    }

    var host: String?
    var uptime: String?
    var uptimeSeconds: Double?
    var procs: Int?
    var hardware: Hardware?
    var healthScore: Double?
    var healthScoreMsg: String?
    var cpu: CPU?
    var gpu: [GPU]?
    var memory: Memory?
    var disks: [Disk]?
    var trashSize: Double?
    var diskIo: DiskIO?
    var network: [Network]?
    var networkHistory: NetworkHistory?
    var batteries: [Battery]?
    var thermal: Thermal?
    var topProcesses: [Process]?
    var bluetooth: [Bluetooth]?

    static func decode(_ data: Data) -> StatusSnapshot? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(StatusSnapshot.self, from: data)
    }

    var rootDisk: Disk? { disks?.first(where: { $0.mount == "/" }) ?? disks?.first }
}
