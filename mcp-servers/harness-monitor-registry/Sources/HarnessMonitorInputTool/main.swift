import ApplicationServices
import CoreGraphics
import Foundation

// Tiny CGEvent-backed input-synthesis CLI. Replaces the external cliclick
// dependency for the harness-monitor MCP server.
//
// Subcommands:
//   move <x> <y>
//   click <x> <y> [--button left|right] [--double]
//   type [--delay <ms>] <text>    (text read from stdin if omitted)
//   position
//   check                         (report Accessibility permission state)
//
// Coordinates are in global screen space, origin at the top-left display.
// Exit codes:
//   0  success
//   1  runtime failure
//   2  accessibility permission denied
//   64 usage error

let args = Array(CommandLine.arguments.dropFirst())
guard let subcommand = args.first else {
  printUsage()
  exit(64)
}

do {
  switch subcommand {
  case "move": try handleMove(Array(args.dropFirst()))
  case "click": try handleClick(Array(args.dropFirst()))
  case "type": try handleType(Array(args.dropFirst()))
  case "position": try handlePosition()
  case "check": try handleCheck()
  case "-h", "--help", "help":
    printUsage()
    exit(0)
  default:
    printUsage()
    exit(64)
  }
} catch let error as InputToolError {
  FileHandle.standardError.write(Data("error: \(error)\n".utf8))
  exit(error.exitCode)
} catch {
  FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
  exit(1)
}

enum InputToolError: Error, CustomStringConvertible {
  case usage(String)
  case invalidNumber(String)
  case invalidButton(String)
  case accessibilityDenied
  case eventCreationFailed(String)

  var description: String {
    switch self {
    case .usage(let msg): return "usage: \(msg)"
    case .invalidNumber(let raw): return "not a number: \(raw)"
    case .invalidButton(let raw): return "unknown button: \(raw)"
    case .accessibilityDenied:
      return "Accessibility permission not granted. Open System Settings -> Privacy & Security -> Accessibility and enable the app running this binary (terminal, Claude Code, etc)."
    case .eventCreationFailed(let what): return "failed to create \(what) event"
    }
  }

  var exitCode: Int32 {
    switch self {
    case .usage: return 64
    case .invalidNumber, .invalidButton: return 64
    case .accessibilityDenied: return 2
    case .eventCreationFailed: return 1
    }
  }
}

func printUsage() {
  let text = """
    harness-monitor-input <subcommand> [args]

    Subcommands:
      move <x> <y>
      click <x> <y> [--button left|right] [--double]
      type [--delay ms] [text]        (reads stdin if text omitted)
      position                        (prints "x,y")
      check                           (prints "trusted" or "denied"; exit 2 if denied)

    All coordinates are global screen coordinates, origin at top-left.
    """
  FileHandle.standardError.write(Data((text + "\n").utf8))
}

func parseDouble(_ raw: String) throws -> Double {
  guard let value = Double(raw) else { throw InputToolError.invalidNumber(raw) }
  return value
}

func requireTrustedAccessibility() throws {
  if AXIsProcessTrusted() == false {
    throw InputToolError.accessibilityDenied
  }
}

func handleMove(_ args: [String]) throws {
  guard args.count >= 2 else { throw InputToolError.usage("move <x> <y>") }
  let x = try parseDouble(args[0])
  let y = try parseDouble(args[1])
  try requireTrustedAccessibility()
  let point = CGPoint(x: x, y: y)
  guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
    throw InputToolError.eventCreationFailed("mouseMoved")
  }
  event.post(tap: .cghidEventTap)
}

enum MouseButton: String {
  case left
  case right

  var downType: CGEventType { self == .left ? .leftMouseDown : .rightMouseDown }
  var upType: CGEventType { self == .left ? .leftMouseUp : .rightMouseUp }
  var cgButton: CGMouseButton { self == .left ? .left : .right }
}

func handleClick(_ args: [String]) throws {
  guard args.count >= 2 else { throw InputToolError.usage("click <x> <y> [--button left|right] [--double]") }
  let x = try parseDouble(args[0])
  let y = try parseDouble(args[1])
  var button: MouseButton = .left
  var double = false
  var i = 2
  while i < args.count {
    let flag = args[i]
    switch flag {
    case "--button":
      guard i + 1 < args.count else { throw InputToolError.usage("--button requires a value") }
      guard let parsed = MouseButton(rawValue: args[i + 1]) else {
        throw InputToolError.invalidButton(args[i + 1])
      }
      button = parsed
      i += 2
    case "--double":
      double = true
      i += 1
    default:
      throw InputToolError.usage("unknown flag: \(flag)")
    }
  }

  try requireTrustedAccessibility()

  let point = CGPoint(x: x, y: y)
  try postClick(at: point, button: button, clickState: 1)
  if double {
    try postClick(at: point, button: button, clickState: 2)
  }
}

func postClick(at point: CGPoint, button: MouseButton, clickState: Int64) throws {
  guard let down = CGEvent(mouseEventSource: nil, mouseType: button.downType, mouseCursorPosition: point, mouseButton: button.cgButton),
        let up = CGEvent(mouseEventSource: nil, mouseType: button.upType, mouseCursorPosition: point, mouseButton: button.cgButton) else {
    throw InputToolError.eventCreationFailed("mouse click")
  }
  down.setIntegerValueField(.mouseEventClickState, value: clickState)
  up.setIntegerValueField(.mouseEventClickState, value: clickState)
  down.post(tap: .cghidEventTap)
  up.post(tap: .cghidEventTap)
}

func handleType(_ args: [String]) throws {
  var delayMillis: UInt32 = 0
  var text: String?
  var i = 0
  while i < args.count {
    let arg = args[i]
    switch arg {
    case "--delay":
      guard i + 1 < args.count else { throw InputToolError.usage("--delay requires a value") }
      guard let value = UInt32(args[i + 1]) else { throw InputToolError.invalidNumber(args[i + 1]) }
      delayMillis = value
      i += 2
    default:
      text = args[i...].joined(separator: " ")
      i = args.count
    }
  }

  if text == nil {
    let stdin = FileHandle.standardInput.readDataToEndOfFile()
    text = String(data: stdin, encoding: .utf8) ?? ""
  }

  guard let typeText = text else { throw InputToolError.usage("type [--delay ms] [text]") }
  if typeText.isEmpty { return }

  try requireTrustedAccessibility()

  let utf16 = Array(typeText.utf16)
  if delayMillis == 0 {
    try postUnicodeString(utf16)
  } else {
    for scalar in typeText.unicodeScalars {
      let chunk = Array(String(scalar).utf16)
      try postUnicodeString(chunk)
      if delayMillis > 0 {
        usleep(useconds_t(delayMillis) * 1_000)
      }
    }
  }
}

func postUnicodeString(_ utf16: [UInt16]) throws {
  guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
    throw InputToolError.eventCreationFailed("keyboard")
  }
  utf16.withUnsafeBufferPointer { buffer in
    guard let base = buffer.baseAddress else { return }
    down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
    up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
  }
  down.post(tap: .cghidEventTap)
  up.post(tap: .cghidEventTap)
}

func handlePosition() throws {
  guard let event = CGEvent(source: nil) else {
    throw InputToolError.eventCreationFailed("cursor query")
  }
  let point = event.location
  FileHandle.standardOutput.write(Data("\(point.x),\(point.y)\n".utf8))
}

func handleCheck() throws {
  if AXIsProcessTrusted() {
    FileHandle.standardOutput.write(Data("trusted\n".utf8))
  } else {
    FileHandle.standardError.write(Data("denied\n".utf8))
    exit(2)
  }
}
