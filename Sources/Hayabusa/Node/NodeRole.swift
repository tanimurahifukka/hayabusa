// hayabusa ノードの役割。command-room WorkerNode.nodeRole と整合。
//   main:       cluster routing 担当 + lease 有効
//   sub:        lease 有効、cluster routing は受けない
//   standalone: lease 無効、chat completions endpoint のみ（既存挙動温存）
//
// CLI / env / config file 経由でロード。

import Foundation

public enum NodeRole: String, Codable, Sendable, CaseIterable {
    case main
    case sub
    case standalone

    public init?(rawValue: String) {
        switch rawValue.lowercased() {
        case "main": self = .main
        case "sub": self = .sub
        case "standalone": self = .standalone
        default: return nil
        }
    }
}
