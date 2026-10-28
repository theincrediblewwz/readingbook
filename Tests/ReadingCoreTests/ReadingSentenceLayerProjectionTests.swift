import Foundation
import XCTest
@testable import ReadingCore

final class ReadingSentenceLayerProjectionTests: XCTestCase {
    private func book(_ text: String) throws -> BookProject {
        BookProject(title: "句旁范围", originalName: "source.pdf", sourceHash: try BookImporter.sha256(Data(text.utf8)),
            units: [SourceUnit(id: "u1", order: 0, chapter: "第一章", page: 1, text: text)])
    }
    private func anchor(_ quote: String, in project: BookProject, unitID: String = "u1") throws -> SourceAnchor {
        try ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: unitID, quote: quote, in: project)
    }
    private func layer(_ id: String, _ anchors: [SourceAnchor], kind: String = "explanation", markdown: String = "这句的解读。") -> ReadingLayer {
        ReadingLayer(id: id, kind: kind, title: id, markdown: markdown, sourceAnchorIDs: anchors.map(\.id))
    }

    func testPageAndParagraphOverlapDoNotBecomeSentenceInterpretation() throws {
        var project = try book("第一句。第二句。\n\n第三句。")
        let hovered = try anchor("第二句。", in: project)
        let paragraph = try anchor("第一句。第二句。", in: project)
        let page = try anchor(project.units[0].text, in: project)
        let exact = layer("exact", [hovered])
        project.readingExperience = ReadingExperienceState(anchors: [hovered, paragraph, page],
            layers: [layer("paragraph", [paragraph]), exact, layer("page", [page])])
        let stored = project.readingExperience, units = project.units
        XCTAssertEqual(ReadingSentenceLayerProjection.exactLayers(for: hovered, in: project), [exact])
        XCTAssertEqual(project.readingExperience, stored, "隐藏宽范围的投影不能删除原先的分析。")
        XCTAssertEqual(project.units, units)
        project.readingExperience?.layers.removeAll { $0.id == exact.id }
        XCTAssertTrue(ReadingSentenceLayerProjection.exactLayers(for: hovered, in: project).isEmpty,
            "只有页面/段落解读时，应让句卡显示译文，不再提供错误的解读fallback。")
    }

    func testOneExactCitationCannotLaunderOtherOrBroaderCitations() throws {
        var project = try book("只看这句话。另一句话。")
        let hovered = try anchor("只看这句话。", in: project), other = try anchor("另一句话。", in: project)
        let broad = try anchor(project.units[0].text, in: project), part = try anchor("这句话", in: project)
        project.readingExperience = ReadingExperienceState(anchors: [hovered, other, broad, part], layers: [
            layer("mixed", [hovered, other]), layer("broad-mixed", [hovered, broad]),
            layer("substring", [part]), layer("other", [other])
        ])
        XCTAssertTrue(ReadingSentenceLayerProjection.exactLayers(for: hovered, in: project).isEmpty)
    }

    func testRepeatedQuotationMustMatchItsVerifiedPosition() throws {
        var project = try book("贾诩入城。贾诩入城。")
        let sentences = ReadingSentenceAnchors.anchors(in: project.units[0], project: project)
        XCTAssertEqual(sentences.count, 2)
        XCTAssertEqual(sentences[0].quote, sentences[1].quote)
        XCTAssertNotEqual(sentences[0].id, sentences[1].id)
        let first = layer("first-place", [sentences[0]]), second = layer("second-place", [sentences[1]])
        project.readingExperience = ReadingExperienceState(anchors: sentences, layers: [first, second])
        XCTAssertEqual(ReadingSentenceLayerProjection.exactLayers(for: sentences[0], in: project), [first])
        XCTAssertEqual(ReadingSentenceLayerProjection.exactLayers(for: sentences[1], in: project), [second])
    }

    func testSameQuotationOnAnotherPageAndInvalidSourceAreRejected() throws {
        var project = try book("相同的话。")
        project.units.append(SourceUnit(id: "u2", order: 1, chapter: "第一章", page: 2, text: "相同的话。"))
        let hovered = try anchor("相同的话。", in: project), elsewhere = try anchor("相同的话。", in: project, unitID: "u2")
        var foreign = hovered; foreign.id = "foreign"; foreign.sourceHash = "other-source"
        var alias = hovered; alias.id = "unverified-alias"
        project.readingExperience = ReadingExperienceState(anchors: [elsewhere, foreign, alias],
            layers: [layer("other-page", [elsewhere]), layer("foreign", [foreign]), layer("alias", [alias])])
        XCTAssertTrue(ReadingSentenceLayerProjection.exactLayers(for: hovered, in: project).isEmpty)
    }

    func testValidLegacyOffsetlessAnchorAndUnicodeRemainReusable() throws {
        var project = try book("前句😀。这一句😀有意义。下一句。")
        let hovered = try anchor("这一句😀有意义。", in: project)
        var legacy = hovered; legacy.utf16Location = nil; legacy.utf16Length = nil
        let exact = layer("legacy-exact", [legacy])
        project.readingExperience = ReadingExperienceState(anchors: [legacy], layers: [exact])
        XCTAssertEqual(ReadingSentenceLayerProjection.exactLayers(for: hovered, in: project), [exact])
        XCTAssertNil(project.readingExperience?.anchors[0].utf16Location,
            "兼容读取旧锚点时，不要迁移或重写用户记录。")
        var halfRange = legacy; halfRange.utf16Location = hovered.utf16Location
        project.readingExperience?.anchors = [halfRange]
        XCTAssertTrue(ReadingSentenceLayerProjection.exactLayers(for: hovered, in: project).isEmpty)
    }

    func testChangedUnitAndDuplicateStoredAnchorAreNotGuessed() throws {
        var project = try book("这一句不变。随后一句。")
        let hovered = try anchor("这一句不变。", in: project)
        project.readingExperience = ReadingExperienceState(anchors: [hovered, hovered], layers: [layer("ambiguous", [hovered])])
        XCTAssertTrue(ReadingSentenceLayerProjection.exactLayers(for: hovered, in: project).isEmpty)
        project.readingExperience?.anchors = [hovered]
        project.units[0].text += "新内容。"
        XCTAssertTrue(ReadingSentenceLayerProjection.exactLayers(for: hovered, in: project).isEmpty,
            "即使引文还在，旧单元哈希也不能沿用为本句解读。")
    }

    func testNewestExactLayersFirstAndTranslationStaysInItsOwnTab() throws {
        var project = try book("只看这句。")
        let hovered = try anchor(project.units[0].text, in: project)
        let old = layer("z-old", [hovered]), middle = layer("m-middle", [hovered]), newest = layer("a-new", [hovered])
        project.readingExperience = ReadingExperienceState(anchors: [hovered], layers: [old, middle,
            layer("translation", [hovered], kind: "translation"), newest, layer("empty", [hovered], markdown: " \n ")])
        XCTAssertEqual(ReadingSentenceLayerProjection.exactLayers(for: hovered, in: project, maximumCount: 2), [newest, middle])
        XCTAssertEqual(ReadingSentenceLayerProjection.exactLayers(for: hovered, in: project), [newest, middle, old])
        XCTAssertTrue(ReadingSentenceLayerProjection.exactLayers(for: hovered, in: project, maximumCount: 0).isEmpty)
    }

    func testMixedHeadingAndProseCannotBecomeSentenceAnalysis() throws {
        let text = "第38回 定三分隆中决策\n却说玄德三顾茅庐。"
        var project = try book(text)
        let mixed = try anchor(text, in: project)
        project.readingExperience = ReadingExperienceState(anchors: [mixed], layers: [layer("old-mixed", [mixed])])
        XCTAssertTrue(ReadingSentenceLayerProjection.exactLayers(for: mixed, in: project).isEmpty)
        XCTAssertEqual(project.readingExperience?.layers.count, 1)
    }
}
