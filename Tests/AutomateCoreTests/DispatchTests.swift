import XCTest
@testable import AutomateCore

final class DispatchTests: XCTestCase {
    func testParsesOneTaskOrMany() throws {
        let one = try Dispatch.parse(Data(#"{"project": "eitri", "title": "Fix login", "message": " do it "}"#.utf8))
        XCTAssertEqual(one, [Dispatch.Task(project: "eitri", title: "Fix login", message: "do it")])

        let id = UUID()
        let many = try Dispatch.parse(Data("""
        [{"thread": "\(id.uuidString)", "message": "now add tests"}, {"thread": "new", "text": "research x"}]
        """.utf8))
        XCTAssertEqual(many, [Dispatch.Task(thread: id, message: "now add tests"), Dispatch.Task(message: "research x")])
    }

    func testRejectsBadTasks() {
        XCTAssertThrowsError(try Dispatch.parse(Data("not json".utf8)))
        XCTAssertThrowsError(try Dispatch.parse(Data(#"{"project": "a"}"#.utf8)))
        XCTAssertThrowsError(try Dispatch.parse(Data(#"{"thread": "abc", "message": "m"}"#.utf8)))
        XCTAssertThrowsError(try Dispatch.parse(Data(#"["m"]"#.utf8)))
    }

    func testReportIsRecognisedAndClipped() {
        let id = UUID()
        let r = Dispatch.report(title: "Fix login", threadId: id, project: "eitri",
                                text: String(repeating: "a", count: 50), stopped: false, failed: true, limit: 10)
        XCTAssertTrue(Dispatch.isReport(r))
        XCTAssertTrue(r.contains(id.uuidString))
        XCTAssertTrue(r.contains("ended with an error"))
        XCTAssertTrue(r.contains("aaaaaaaaaa\n… (cut"))
        XCTAssertFalse(Dispatch.isReport("please report from the field"))
    }

    func testPromptListsProjectsThreadsAndBudget() {
        let id = UUID()
        let p = Dispatch.coordinatorPrompt(outbox: URL(fileURLWithPath: "/tmp/out"),
                                           projects: [("eitri", "/code/eitri")],
                                           threads: [.init(id: id, title: "Fix login", project: "eitri", running: true)],
                                           budgetLeft: 7)
        XCTAssertTrue(p.contains("/tmp/out/<short-name>.json"))
        XCTAssertTrue(p.contains("- eitri: /code/eitri"))
        XCTAssertTrue(p.contains("\(id.uuidString) · Fix login · eitri · working"))
        XCTAssertTrue(p.contains("7 more task(s)"))
    }
}
