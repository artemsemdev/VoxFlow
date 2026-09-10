import Foundation
import Testing
@testable import VoxFlowMCP

@Suite("JSONValue")
struct JSONValueTests {
    @Test("round-trips a nested object through JSONEncoder/JSONDecoder")
    func roundTripsNestedObject() throws {
        let value = JSONValue.object([
            "name": .string("VoxFlow"),
            "count": .int(42),
            "ratio": .double(3.5),
            "enabled": .bool(true),
            "nothing": .null,
            "tags": .array([.string("a"), .string("b")]),
            "nested": .object(["inner": .int(7)]),
        ])

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(decoded == value)

        guard case .int(let count)? = decoded["count"] else {
            Issue.record("expected count to decode as .int")
            return
        }
        #expect(count == 42)

        guard case .double(let ratio)? = decoded["ratio"] else {
            Issue.record("expected ratio to decode as .double")
            return
        }
        #expect(ratio == 3.5)

        guard case .int(let inner)? = decoded["nested"]?["inner"] else {
            Issue.record("expected nested.inner to decode as .int")
            return
        }
        #expect(inner == 7)
    }

    @Test("a fractional number round-trips as .double")
    func fractionalValueRoundTripsAsDouble() throws {
        let data = try JSONEncoder().encode(JSONValue.double(3.5))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == .double(3.5))
    }

    @Test("a whole-number double is NOT preserved across the wire: it encodes as a plain integer and decodes back as .int, by design")
    func wholeNumberDoubleIsNotPreservedAcrossEncodeDecode() throws {
        let data = try JSONEncoder().encode(JSONValue.double(3.0))
        #expect(String(data: data, encoding: .utf8) == "3")

        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == .int(3))
    }

    @Test("subscript and typed accessors read object fields")
    func subscriptAndTypedAccessors() {
        let value = JSONValue.object([
            "s": .string("hi"),
            "i": .int(1),
            "b": .bool(false),
            "a": .array([.int(1), .int(2)]),
            "o": .object(["x": .int(9)]),
        ])

        #expect(value["s"]?.stringValue == "hi")
        #expect(value["i"]?.intValue == 1)
        #expect(value["b"]?.boolValue == false)
        #expect(value["a"]?.arrayValue?.count == 2)
        #expect(value["o"]?.objectValue?["x"]?.intValue == 9)
        #expect(value["missing"] == nil)
        #expect(value["s"]?.intValue == nil)
    }

    @Test("null encodes and decodes as JSON null")
    func nullRoundTrips() throws {
        let data = try JSONEncoder().encode(JSONValue.null)
        #expect(String(data: data, encoding: .utf8) == "null")
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == .null)
    }
}
