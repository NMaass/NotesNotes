import Foundation
import SwiftUI
import Testing
@testable import ResonoteKit

@Suite struct RichTextTests {
    private let webDocument = RichDocument(content: [
        DocNode(type: "paragraph", content: [
            DocNode(type: "text", text: "The chorus "),
            DocNode(type: "text", text: "changes shape", marks: [DocNode.Mark(type: "bold")]),
            DocNode(type: "text", text: " like "),
            DocNode(type: "musicReference", attrs: ["referenceId": "r1", "id": "s2", "label": "When You Sleep", "entityKind": "song", "relation": "reminds-me-of", "lenses": .array(["production"])]),
            DocNode(type: "text", text: " does."),
        ]),
        DocNode(type: "paragraph"),
        DocNode(type: "paragraph", content: [DocNode(type: "text", text: "Second thought.")]),
    ])

    @Test func roundTripsReferencesAndParagraphs() {
        let text = RichTextCodec.editableText(from: webDocument)
        #expect(String(text.characters) == "The chorus changes shape like When You Sleep does.\n\nSecond thought.")
        let document = RichTextCodec.document(from: text)
        #expect(document.content.count == 3)
        let reference = document.references.first
        #expect(reference?.id == "r1")
        #expect(reference?.relation == .remindsMeOf)
        #expect(reference?.lenses == [.production])
        #expect(document.plainText == "The chorus changes shape like When You Sleep does.\n\n\n\nSecond thought.")
    }

    @Test func detectsTriggerBeforeCaret() {
        let text = AttributedString("Sounds like \\when yo")
        let selection = AttributedTextSelection(insertionPoint: text.endIndex)
        let trigger = RichTextCodec.activeTrigger(in: text, selection: selection)
        #expect(trigger?.query == "when yo")
        let noTrigger = RichTextCodec.activeTrigger(in: AttributedString("No trigger here"), selection: AttributedTextSelection(insertionPoint: AttributedString("No trigger here").endIndex))
        #expect(noTrigger == nil)
    }

    @Test func insertsTokenAndKeepsItAtomic() {
        var text = AttributedString("Sounds like \\when")
        var selection = AttributedTextSelection(insertionPoint: text.endIndex)
        let trigger = RichTextCodec.activeTrigger(in: text, selection: selection)!
        RichTextCodec.insert(MusicRefValue(referenceId: "r9", entityId: "s2", label: "When You Sleep", entityKind: .song), replacing: trigger.range, in: &text, selection: &selection)
        #expect(String(text.characters) == "Sounds like When You Sleep ")
        #expect(RichTextCodec.references(in: text).map(\.id) == ["r9"])
        // The caret sits after the inserted space, so typing appends instead of replacing the token.
        guard case .insertionPoint(let caret) = selection.indices(in: text) else {
            Issue.record("selection should be a caret after insertion")
            return
        }
        #expect(caret == text.endIndex)
        text.replaceSelection(&selection, withCharacters: "x")
        #expect(String(text.characters) == "Sounds like When You Sleep x")
        #expect(RichTextCodec.references(in: text).count == 1)

        // Delete one character inside the token: the whole token goes.
        let tokenEnd = text.characters.index(text.startIndex, offsetBy: "Sounds like When You Sleep".count)
        text.removeSubrange(text.characters.index(before: tokenEnd)..<tokenEnd)
        let changed = RichTextCodec.enforceAtomicReferences(in: &text, selection: &selection)
        #expect(changed)
        #expect(String(text.characters) == "Sounds like  x")
        #expect(RichTextCodec.references(in: text).isEmpty)
    }

    @Test func flattensWebStructure() {
        let document = RichDocument(content: [
            DocNode(type: "heading", attrs: ["level": .number(2)], content: [DocNode(type: "text", text: "Title")]),
            DocNode(type: "bulletList", content: [
                DocNode(type: "listItem", content: [DocNode(type: "paragraph", content: [DocNode(type: "text", text: "one")])]),
                DocNode(type: "listItem", content: [DocNode(type: "paragraph", content: [DocNode(type: "text", text: "two")])]),
            ]),
        ])
        #expect(document.hasBlocksBeyondParagraphs)
        #expect(String(RichTextCodec.editableText(from: document).characters) == "Title\n• one\n• two")
    }

    @Test func updatesReferenceMetadata() {
        var text = RichTextCodec.editableText(from: webDocument)
        RichTextCodec.updateReference("r1", relation: .pairsWith, lenses: [.feeling], in: &text)
        let reference = RichTextCodec.references(in: text).first
        #expect(reference?.relation == .pairsWith)
        #expect(reference?.lenses == [.feeling])
    }

    @Test func boldSurvivesThroughInlineIntent() {
        var text = AttributedString("plain ")
        var strong = AttributedString("loud")
        strong.inlinePresentationIntent = .stronglyEmphasized
        text.append(strong)
        let document = RichTextCodec.document(from: text)
        let nodes = document.content.first?.content ?? []
        #expect(nodes.count == 2)
        #expect(nodes.last?.marks?.map(\.type) == ["bold"])
    }
}

@Suite struct HelperTests {
    @Test func slugsMatchWeb() {
        #expect(Slug.make("Fluorescent Parking Lots at 2am!") == "fluorescent-parking-lots-at-2am")
        #expect(Slug.make("Rock & Roll") == "rock-and-roll")
        #expect(Slug.make("Don’t Stop") == "dont-stop")
        #expect(Slug.unique("Mix", taken: ["mix", "mix-2"]) == "mix-3")
        #expect(Slug.unique("!!!", taken: []) == "untitled-collection")
    }

    @Test func catalogIndexSubtitles() throws {
        var index = CatalogIndex()
        index.absorb(CatalogSlice(artists: [Artist(id: "a", name: "Nirvana", slug: "nirvana", country: "US")], albums: [Album(id: "al", name: "Nevermind", slug: "nevermind", artistId: "a", imageUrl: "https://x/cover.jpg", year: 1991)], songs: [Song(id: "s", name: "Lithium", slug: "lithium", artistId: "a", albumId: "al")]))
        let song = try #require(index.entity(id: "s"))
        let album = try #require(index.entity(id: "al"))
        let artist = try #require(index.entity(id: "a"))
        #expect(index.subtitle(for: song) == "Nirvana · Nevermind")
        #expect(index.artworkURL(for: song) == "https://x/cover.jpg")
        #expect(index.subtitle(for: album) == "Nirvana · 1991")
        #expect(index.subtitle(for: artist) == "US · Artist")
    }
}
