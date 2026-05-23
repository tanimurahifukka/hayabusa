import Foundation
import Hummingbird
import HTTPTypes

/// Encodable な値を Hummingbird Response として content-type=application/json 付きで返すヘルパ。
///
/// 既存の手組み JSON 文字列 (`"{\"status\":\"ok\"}"`) を順次これに置き換える。
/// String を直接 return すると Hummingbird は text/plain で返してしまい、
/// curl やクライアント側が JSON として解釈しないことがあるため。
///
/// 使い方:
/// ```swift
/// router.get("health") { _, _ -> Response in
///     try jsonResponse(HealthResponse(status: "ok"))
/// }
/// ```
func jsonResponse<T: Encodable>(
    _ value: T,
    status: HTTPResponse.Status = .ok,
    encoder: JSONEncoder = .hayabusaDefault
) throws -> Response {
    let data = try encoder.encode(value)
    return Response(
        status: status,
        headers: [.contentType: "application/json; charset=utf-8"],
        body: ResponseBody(byteBuffer: .init(bytes: data))
    )
}

extension JSONEncoder {
    /// Hayabusa 既定: 互換用の sortedKeys, 余分な空白なし。
    static var hayabusaDefault: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }
}

/// /health 用の最小レスポンス。
struct HealthResponse: Encodable, Sendable {
    let status: String
}
