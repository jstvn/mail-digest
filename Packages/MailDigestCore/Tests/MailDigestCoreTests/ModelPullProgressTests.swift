import Foundation
import Testing
@testable import MailDigestCore

@Suite struct ModelPullProgressTests {
    private func feed(_ lines: [String]) -> ModelPullProgress {
        var progress = ModelPullProgress()
        for line in lines { if let event = ModelPullEvent.decode(line: line) { progress.apply(event) } }
        return progress
    }

    @Test func decodesRecordedLines() throws {
        let manifest = try #require(ModelPullEvent.decode(line: #"{"status":"pulling manifest"}"#))
        #expect(manifest.status == "pulling manifest" && manifest.total == nil)
        let layer = try #require(ModelPullEvent.decode(line: #"{"status":"pulling 6a0746a1ec1a","digest":"sha256:6a07","total":2497281120,"completed":1198693017}"#))
        #expect(layer.digest == "sha256:6a07" && layer.total == 2_497_281_120 && layer.completed == 1_198_693_017)
    }

    @Test func ignoresTruncatedUnknownAndBlankLines() {
        #expect(ModelPullEvent.decode(line: #"{"status":"pulling 6a07","dige"#) == nil)
        #expect(ModelPullEvent.decode(line: "") == nil)
        #expect(ModelPullEvent.decode(line: #"{"hello":"world"}"#) == nil)
        #expect(ModelPullEvent.decode(line: "not json") == nil)
    }

    @Test func overallFigureNeverMovesBackwardsAcrossLayers() {
        var progress = ModelPullProgress()
        progress.apply(ModelPullEvent(status: "pulling a", digest: "a", total: 1000, completed: 1000))
        let before = progress.completedBytes
        // A new layer appears: the total grows, completed bytes stay.
        progress.apply(ModelPullEvent(status: "pulling b", digest: "b", total: 3000, completed: 0))
        #expect(progress.completedBytes >= before)
        #expect(progress.totalBytes == 4000)
        #expect(progress.fraction == 0.25)
        // A repeated, smaller report for a layer doesn't regress.
        progress.apply(ModelPullEvent(status: "pulling a", digest: "a", total: 1000, completed: 10))
        #expect(progress.completedBytes == 1000)
    }

    @Test func successCompletes() {
        let progress = feed([#"{"status":"pulling manifest"}"#,
                             #"{"status":"pulling a","digest":"a","total":10,"completed":10}"#,
                             #"{"status":"verifying sha256 digest"}"#, #"{"status":"success"}"#])
        #expect(progress.outcome == .succeeded)
    }

    @Test func errorLineFailsWithOllamasMessage() {
        let progress = feed([#"{"status":"pulling manifest"}"#, #"{"error":"pull model manifest: file does not exist"}"#])
        #expect(progress.outcome == .failed("pull model manifest: file does not exist"))
    }

    @Test func formatsText() {
        #expect(ModelPullProgress().text == "Preparing…")
        let progress = feed([#"{"status":"pulling a","digest":"a","total":2500000000,"completed":1200000000}"#])
        #expect(progress.text == "1.2 GB of 2.5 GB · 48%")
        #expect(ModelPullProgress.bytes(512_000_000) == "512 MB")
        #expect(ModelPullProgress.bytes(12) == "12 bytes")
    }
}
