import AppKit

// Bound CoreText paragraph context without inserting characters or replacing
// native selection/input. Only wrapped large-text presentation uses this path.
final class BudgetTypesetter:NSATSTypesetter {
    weak var owner:NSLayoutManager?
    var glyphBudget=0
    override func setParagraphGlyphRange(_ paragraphRange:NSRange,separatorGlyphRange separator:NSRange) {
        guard glyphBudget>0,paragraphRange.length>glyphBudget,let owner,let storage=owner.textStorage else {
            super.setParagraphGlyphRange(paragraphRange,separatorGlyphRange:separator);return
        }
        let proposed=paragraphRange.location+glyphBudget
        let character=owner.characterIndexForGlyph(at:proposed)
        guard character<storage.length else {super.setParagraphGlyphRange(paragraphRange,separatorGlyphRange:separator);return}
        // A glyph boundary can still be inside a composed cluster (emoji/marks).
        let cluster=(storage.string as NSString).rangeOfComposedCharacterSequence(at:character)
        let end=owner.glyphIndexForCharacter(at:cluster.location)
        guard end>paragraphRange.location,end<=proposed else {
            // One pathological cluster exceeds the budget: retain native layout.
            super.setParagraphGlyphRange(paragraphRange,separatorGlyphRange:separator);return
        }
        super.setParagraphGlyphRange(NSRange(location:paragraphRange.location,length:end-paragraphRange.location),separatorGlyphRange:NSRange(location:end,length:0))
    }
}
