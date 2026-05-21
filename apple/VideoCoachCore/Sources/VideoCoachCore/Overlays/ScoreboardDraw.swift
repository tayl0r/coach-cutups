import CoreGraphics
import CoreText
import Foundation

/// Draws the broadcast scoreboard overlay anchored to the top-left of `size`.
/// Caller MUST have set up top-left user space — the convention
/// `CompilationCompositor` uses after its `translateBy/scaleBy(-1)` flip;
/// AppKit's `NSView.draw(_:)` provides this through
/// `NSGraphicsContext.current!.cgContext` when the view has `isFlipped = true`.
public func drawScoreboard(into cg: CGContext, size: CGSize, state: ScoreboardState) {
    let barH = size.height * 0.08
    let barW = size.width  * 0.36
    let inset = size.height * 0.015
    let topY = inset
    let leftX = inset

    let accentH = barH * 0.08
    let scoreBarH = barH - accentH

    let homeW  = barW * 0.30
    let scoreW = barW * 0.20
    let awayW  = barW * 0.30
    let clockW = barW * 0.20

    func cgColor(_ c: RGBA) -> CGColor {
        CGColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    let scoreRowY = topY + accentH
    let homeRect  = CGRect(x: leftX,                              y: scoreRowY, width: homeW,  height: scoreBarH)
    let scoreRect = CGRect(x: leftX + homeW,                      y: scoreRowY, width: scoreW, height: scoreBarH)
    let awayRect  = CGRect(x: leftX + homeW + scoreW,             y: scoreRowY, width: awayW,  height: scoreBarH)
    let clockRect = CGRect(x: leftX + homeW + scoreW + awayW,     y: scoreRowY, width: clockW, height: scoreBarH)

    cg.setFillColor(cgColor(state.home.primaryColor)); cg.fill(homeRect)
    cg.setFillColor(cgColor(RGBA(r: 0.1, g: 0.1, b: 0.1, a: 1))); cg.fill(scoreRect)
    cg.setFillColor(cgColor(state.away.primaryColor)); cg.fill(awayRect)
    cg.setFillColor(cgColor(RGBA(r: 0.05, g: 0.05, b: 0.05, a: 0.95))); cg.fill(clockRect)

    cg.setFillColor(cgColor(state.home.secondaryColor))
    cg.fill(CGRect(x: leftX, y: topY, width: homeW, height: accentH))
    cg.setFillColor(cgColor(state.away.secondaryColor))
    cg.fill(CGRect(x: leftX + homeW + scoreW, y: topY, width: awayW, height: accentH))

    let labels = formatClock(state.clock)
    // Both team names render at the same size — the smaller of the two
    // fitted sizes — so the bar reads symmetrically.
    let teamFontDesired = scoreBarH * 0.55
    let teamPad: CGFloat = 4
    let homeFit = fittingFontSize(for: state.home.name, maxWidth: homeW - teamPad * 2,
                                  desiredSize: teamFontDesired, bold: true)
    let awayFit = fittingFontSize(for: state.away.name, maxWidth: awayW - teamPad * 2,
                                  desiredSize: teamFontDesired, bold: true)
    let teamFontSize = min(homeFit, awayFit)
    drawText(state.home.name, in: homeRect, fontSize: teamFontSize, bold: true,
             color: cgColor(state.home.fontColor), into: cg)
    drawText("\(state.homeScore) - \(state.awayScore)", in: scoreRect, fontSize: scoreBarH * 0.55, bold: true, into: cg)
    drawText(state.away.name, in: awayRect, fontSize: teamFontSize, bold: true,
             color: cgColor(state.away.fontColor), into: cg)
    drawText(labels.main, in: clockRect, fontSize: scoreBarH * 0.55, bold: true, into: cg)
    if !labels.trailing.isEmpty {
        // Wide enough for "+MM:SS" stoppage tail.
        let plusRect = CGRect(x: clockRect.maxX + 2, y: scoreRowY, width: clockW * 1.0, height: scoreBarH)
        drawText(labels.trailing, in: plusRect, fontSize: scoreBarH * 0.45, bold: false, into: cg)
    }
}

private func ctFont(size: CGFloat, bold: Bool) -> CTFont {
    let base = CTFontCreateUIFontForLanguage(.system, size, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    guard bold else { return base }
    let traits: CTFontSymbolicTraits = .boldTrait
    return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
}

/// Typographic advance width of a single line — string-independent
/// horizontal extent, the right primitive for layout.
private func lineWidth(text: String, font: CTFont) -> CGFloat {
    let attrs: [CFString: Any] = [kCTFontAttributeName: font]
    guard let attributed = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)
    else { return 0 }
    let line = CTLineCreateWithAttributedString(attributed)
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}

/// Largest font size ≤ `desiredSize` at which `text` renders inside `maxWidth`.
/// Single measurement; proportional shrink. 6pt absolute floor keeps a
/// pathological name legible.
private func fittingFontSize(for text: String, maxWidth: CGFloat, desiredSize: CGFloat, bold: Bool) -> CGFloat {
    guard !text.isEmpty, maxWidth > 0, desiredSize > 0 else { return desiredSize }
    let measured = lineWidth(text: text, font: ctFont(size: desiredSize, bold: bold))
    guard measured > maxWidth else { return desiredSize }
    return max(6, desiredSize * maxWidth / measured)
}

/// Renders `s` centered in `rect`, assuming the caller's context is in
/// top-left user space (Y down). Uses `textMatrix(1, -1)` to flip glyphs
/// locally (so ascenders extend visually upward in the top-left CTM)
/// without modifying the context's CTM. Uses font metrics (ascent/descent)
/// for vertical centering so different strings in the same row share a
/// consistent visual baseline. CoreText is thread-safe — usable from the
/// compositor's private render queue.
private func drawText(
    _ s: String, in rect: CGRect, fontSize: CGFloat, bold: Bool,
    color: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1),
    into cg: CGContext
) {
    guard !s.isEmpty else { return }
    let font = ctFont(size: fontSize, bold: bold)
    let attrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: color,
    ]
    guard let attributed = CFAttributedStringCreate(nil, s as CFString, attrs as CFDictionary)
    else { return }
    let line = CTLineCreateWithAttributedString(attributed)
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    let ascent = CTFontGetAscent(font)
    let descent = CTFontGetDescent(font)

    cg.saveGState()
    // Flip glyphs locally so ascenders extend toward smaller Y (visually
    // upward in top-left CTM). textMatrix isn't part of saved graphics
    // state, so the next caller re-sets it — no leakage.
    cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    // In top-left coords: ascender extends from baseline toward smaller Y,
    // descender toward larger Y. Visual center is
    // baseline - (ascent - descent)/2. Solve for baseline given midY:
    let baselineY = rect.midY + (ascent - descent) / 2
    let textX = rect.midX - width / 2
    cg.textPosition = CGPoint(x: textX, y: baselineY)
    CTLineDraw(line, cg)
    cg.restoreGState()
}
