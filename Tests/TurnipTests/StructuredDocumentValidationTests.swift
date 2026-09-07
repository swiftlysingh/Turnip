import Foundation
import Testing
import Turnip

@Test(arguments: [
    #"{"rows":[]}"#,
    #"{"rows":[{"cells":[{"state":"empty"}]},{"cells":[{"state":"empty"},{"state":"empty"}]}]}"#,
    #"{"rows":[{"cells":[{"state":"covered","coveredBy":{"row":0,"column":0}}]}]}"#,
    #"{"rows":[{"cells":[{"state":"empty"}]},{"cells":[{"state":"text","lines":[{"text":"Value"}],"span":{"rows":9223372036854775807,"columns":1}}]}]}"#,
    #"{"rows":[{"cells":[{"state":"empty"},{"state":"text","lines":[{"text":"Value"}],"span":{"rows":1,"columns":9223372036854775807}}]}]}"#,
])
func malformedTableJSONThrowsThroughBothDecodingEntrypoints(_ tableJSON: String) throws {
    let data = Data(tableJSON.utf8)
    #expect(throws: Error.self) {
        _ = try JSONDecoder().decode(TableBlock.self, from: data)
    }

    var content = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    content["type"] = "table"
    let block = try JSONSerialization.data(withJSONObject: ["id": "test-table", "content": content])
    #expect(throws: Error.self) {
        _ = try JSONDecoder().decode(DocumentBlock.self, from: block)
    }
}
