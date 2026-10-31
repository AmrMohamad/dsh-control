import Testing
@testable import DSHControlCore

@Suite struct InputTests {
    @Test func draftComparisonToleratesPageNormalization() {
        #expect(UIController.sameDraft("a\nb", "a\nb"))
        #expect(UIController.sameDraft("tail\n\n", "tail\n"))
        #expect(UIController.sameDraft("", "  \n "))
        #expect(!UIController.sameDraft("x", "  "))
        #expect(!UIController.sameDraft("old", "new"))
        #expect(!UIController.sameDraft(nil, ""))
    }
}
