import SwiftUI

struct HarnessCodeBlockPresentation: Equatable, Sendable {
  let source: String
  let language: HarnessCodeLanguage
  let tokens: [HarnessCodeToken]
  let attributedText: AttributedString
  let errorMessage: String?

  init(
    source: String,
    language: HarnessCodeLanguage,
    tokens: [HarnessCodeToken]? = nil,
    errorMessage: String? = nil
  ) {
    self.source = source
    self.language = language
    self.tokens = tokens ?? HarnessCodeHighlighter.highlight(source, language: language)
    attributedText = HarnessCodeHighlighter.makeAttributedString(from: self.tokens)
    self.errorMessage = errorMessage
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.source == rhs.source
      && lhs.language == rhs.language
      && lhs.tokens == rhs.tokens
      && lhs.errorMessage == rhs.errorMessage
  }
}

struct HarnessMonitorCodeBlock: View {
  enum Chrome {
    case card
    case plain
  }

  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast
  @Environment(\.fontScale)
  private var environmentFontScale

  let presentation: HarnessCodeBlockPresentation
  let settings: HarnessCodeBlockRenderSettings
  let chrome: Chrome
  let wrapLongLines: Bool

  init(
    presentation: HarnessCodeBlockPresentation,
    settings: HarnessCodeBlockRenderSettings = .default,
    chrome: Chrome = .card,
    wrapLongLines: Bool = false
  ) {
    self.presentation = presentation
    self.settings = settings
    self.chrome = chrome
    self.wrapLongLines = wrapLongLines
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      header
      errorMessage
      codeContent
    }
    .padding(contentPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background { backgroundShape.fill(style.colors.background.opacity(backgroundOpacity)) }
    .overlay {
      backgroundShape.stroke(
        style.colors.border.opacity(borderOpacity),
        lineWidth: borderLineWidth
      )
    }
    .accessibilityElement(children: .contain)
  }

  private var header: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Text(presentation.language.displayName ?? "Code")
        .font(style.typography.label.font)
        .foregroundStyle(style.colors.label)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      Button {
        HarnessMonitorClipboard.copy(presentation.source)
      } label: {
        Image(systemName: "doc.on.doc")
          .frame(width: 16, height: 16)
      }
      .buttonStyle(.borderless)
      .help("Copy code")
      .accessibilityLabel("Copy code")
    }
  }

  @ViewBuilder private var errorMessage: some View {
    if let errorMessage = presentation.errorMessage {
      Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
        .font(style.typography.error.font)
        .foregroundStyle(style.colors.error)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder private var codeContent: some View {
    if wrapLongLines {
      codeText
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      ScrollView(.horizontal) {
        codeText
          .fixedSize(horizontal: true, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var codeText: some View {
    Text(
      HarnessCodeHighlighter.makeAttributedString(
        from: presentation.tokens,
        colors: style.colors.tokens
      )
    )
    .font(style.typography.code.font)
    .textSelection(.enabled)
  }

  private var style: HarnessCodeBlockResolvedSettings {
    settings.resolved(environmentFontScale: environmentFontScale)
  }

  private var contentPadding: CGFloat {
    switch chrome {
    case .card:
      HarnessMonitorTheme.spacingSM
    case .plain:
      0
    }
  }

  private var backgroundShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
  }

  private var backgroundOpacity: Double {
    switch chrome {
    case .card:
      colorSchemeContrast == .increased ? 0.1 : 0.05
    case .plain:
      0
    }
  }

  private var borderOpacity: Double {
    switch chrome {
    case .card:
      colorSchemeContrast == .increased ? 0.9 : 0.6
    case .plain:
      0
    }
  }

  private var borderLineWidth: CGFloat {
    switch chrome {
    case .card:
      colorSchemeContrast == .increased ? 2 : 1
    case .plain:
      0
    }
  }
}
