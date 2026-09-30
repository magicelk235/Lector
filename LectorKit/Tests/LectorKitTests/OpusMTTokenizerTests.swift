import XCTest
@testable import LectorKit

/// The tokenizer against a tiny Marian tokenizer built by the reference SentencePiece
/// library (Scripts/make-opus-tokenizer-fixture.py). The expected ids are what that library
/// and transformers' MarianTokenizer produce; a model fed different ids translates
/// something other than what is on screen.
final class OpusMTTokenizerTests: XCTestCase {
    private func tokenizer() throws -> MarianTokenizer {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return try MarianTokenizer(directory: fixtures.appending(path: "opus-tokenizer"))
    }

    /// Everything the normaliser and segmenter must get right at once: surrounding and
    /// repeated whitespace, full-width letters, a no-break space, an ellipsis, a ligature,
    /// an accent typed as a separate combining mark, a run of characters the model has
    /// never seen (one <unk>, not two), and Hebrew, behind a target-language token.
    func testEncodesLikeTheReferenceImplementation() throws {
        let sentence = "  Ｈｅｌｌｏ\u{00A0} world…  ﬁne cafe\u{0301} 😀😀 שלום  "

        let ids = try tokenizer().encode(sentence, languageToken: ">>heb<<")

        XCTAssertEqual(ids, [202, 2, 100, 182, 183, 56, 70, 69, 10, 10, 10, 27, 71, 2, 89, 12, 29, 42, 2, 1, 75, 25, 0])
    }

    func testDecodingGivesBackTheNormalisedText() throws {
        let tokenizer = try tokenizer()

        let ids = tokenizer.encode("Ｈｅｌｌｏ world…  ﬁne cafe\u{0301} שלום", languageToken: ">>heb<<")

        XCTAssertEqual(tokenizer.decode(ids), "Hello world... fine café שלום",
                       "the language token and </s> are not text")
    }
}

