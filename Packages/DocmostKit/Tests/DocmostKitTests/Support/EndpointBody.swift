import Foundation
@testable import DocmostKit

func body(of endpoint: Endpoint<some Decodable & Sendable>) throws -> [String: JSONValue] {
    try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(endpoint.body))
}
