import Testing

@testable import HarnessMonitorKit

@Suite("AgentTuiKey")
struct AgentTuiKeyTests {
  @Test("keyboard glyphs use platform key symbols")
  func keyboardGlyphsUsePlatformKeySymbols() {
    #expect(AgentTuiKey.enter.glyph == "↩")
    #expect(AgentTuiKey.tab.glyph == "⇥")
    #expect(AgentTuiKey.escape.glyph == "⎋")
    #expect(AgentTuiKey.backspace.glyph == "⌫")
    #expect(AgentTuiKey.arrowUp.glyph == "↑")
    #expect(AgentTuiKey.arrowDown.glyph == "↓")
    #expect(AgentTuiKey.arrowLeft.glyph == "←")
    #expect(AgentTuiKey.arrowRight.glyph == "→")
  }
}
