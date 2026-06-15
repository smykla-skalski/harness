import Foundation

enum HarnessMarkdownEmojiAliases {
  static func replacingAliases(in source: String) -> String {
    guard source.contains(":") else { return source }

    var result = ""
    var index = source.startIndex
    while index < source.endIndex {
      guard source[index] == ":" else {
        result.append(source[index])
        index = source.index(after: index)
        continue
      }

      let aliasStart = source.index(after: index)
      var aliasEnd = aliasStart
      while aliasEnd < source.endIndex, source[aliasEnd].isGitHubEmojiAliasCharacter {
        aliasEnd = source.index(after: aliasEnd)
      }

      if aliasEnd < source.endIndex,
        source[aliasEnd] == ":",
        aliasEnd > aliasStart
      {
        let alias = String(source[aliasStart..<aliasEnd]).lowercased()
        if let emoji = emoji(for: alias) {
          result.append(emoji)
          index = source.index(after: aliasEnd)
          continue
        }
      }

      result.append(source[index])
      index = source.index(after: index)
    }
    return result
  }

  private static func emoji(for alias: String) -> String? {
    aliases[alias]
  }

  private static let aliases: [String: String] = [
    "+1": "👍",
    "-1": "👎",
    "100": "💯",
    "bangbang": "‼️",
    "boom": "💥",
    "bulb": "💡",
    "calendar": "📆",
    "construction": "🚧",
    "eyes": "👀",
    "fire": "🔥",
    "gear": "⚙️",
    "grey_exclamation": "❕",
    "grey_question": "❔",
    "hammer": "🔨",
    "heavy_check_mark": "✔️",
    "heavy_multiplication_x": "✖️",
    "information_source": "ℹ️",
    "interrobang": "⁉️",
    "key": "🔑",
    "label": "🏷️",
    "link": "🔗",
    "lock": "🔒",
    "mag": "🔍",
    "mag_right": "🔎",
    "memo": "📝",
    "no_entry": "⛔",
    "package": "📦",
    "paperclip": "📎",
    "point_down": "👇",
    "point_left": "👈",
    "point_right": "👉",
    "point_up": "☝️",
    "pushpin": "📌",
    "question": "❓",
    "recycle": "♻️",
    "rocket": "🚀",
    "rotating_light": "🚨",
    "sparkles": "✨",
    "tada": "🎉",
    "unlock": "🔓",
    "warning": "⚠️",
    "white_check_mark": "✅",
    "wrench": "🔧",
    "x": "❌",
    "zap": "⚡",
  ]
}

extension Character {
  fileprivate var isGitHubEmojiAliasCharacter: Bool {
    isLetter || isNumber || self == "_" || self == "+" || self == "-"
  }
}
