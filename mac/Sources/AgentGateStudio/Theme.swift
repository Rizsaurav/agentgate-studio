import SwiftUI

/// The Studio palette, the same tokens as the desktop web app (apps/web/app/globals.css).
enum Theme {
  static let bg = Color(hex: 0x101115)
  static let sidebar = Color(hex: 0x0D0E12)
  static let surface = Color(hex: 0x17181E)
  static let raised = Color(hex: 0x202129)
  static let line = Color(hex: 0x292A34)
  static let text = Color(hex: 0xEDEDF2)
  static let muted = Color(hex: 0xA0A1B1)
  static let accent = Color(hex: 0xB69AF1)
  static let accentBg = Color(hex: 0x292238)
  static let button = Color(hex: 0x9A7BDD)
  static let success = Color(hex: 0x8AD1AA)
  static let danger = Color(hex: 0xF1A3A6)
  static let warning = Color(hex: 0xF2C97D)
}

extension Color {
  init(hex: UInt32) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
}

/// Small uppercase label above page titles ("Your local workspace").
struct Eyebrow: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text).font(.system(size: 11, weight: .medium)).tracking(0.6).foregroundStyle(Theme.accent)
  }
}

/// Page heading: eyebrow, large title, one-line description.
struct PageHeading: View {
  let eyebrow: String
  let title: String
  let detail: String
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Eyebrow(eyebrow)
      Text(title).font(.system(size: 30, weight: .bold)).tracking(-0.6).foregroundStyle(Theme.text)
      Text(detail).font(.system(size: 14)).foregroundStyle(Theme.muted).lineSpacing(4)
        .frame(maxWidth: 620, alignment: .leading)
    }
  }
}

/// Rounded panel with the surface colour and a hairline border.
struct Card<Content: View>: View {
  var padding: CGFloat = 24
  @ViewBuilder var content: Content
  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
      .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
  }
}

/// A square tile holding an icon, as used for empty states and list rows.
struct IconTile: View {
  let symbol: String
  var size: CGFloat = 46
  var body: some View {
    Image(systemName: symbol).font(.system(size: size * 0.4)).foregroundStyle(Theme.accent)
      .frame(width: size, height: size)
      .background(RoundedRectangle(cornerRadius: size * 0.26).fill(Theme.accentBg))
  }
}

struct StatusPill: View {
  enum Tone { case ok, neutral, bad, pending }
  let text: String
  let tone: Tone
  var body: some View {
    Text(text).font(.system(size: 11, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 4)
      .foregroundStyle(color).background(Capsule().fill(color.opacity(0.14)))
  }

  private var color: Color {
    switch tone {
    case .ok: Theme.success
    case .neutral: Theme.muted
    case .bad: Theme.danger
    case .pending: Theme.warning
    }
  }
}

struct PrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    PrimaryButtonBody(configuration: configuration)
  }

  private struct PrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    var body: some View {
      configuration.label.font(.system(size: 14, weight: .medium)).foregroundStyle(Color(hex: 0x15121F))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.button.opacity(enabled ? 1 : 0.5)))
        .opacity(configuration.isPressed ? 0.85 : 1)
    }
  }
}

struct SubtleButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 13)).foregroundStyle(Theme.text)
      .padding(.horizontal, 12).padding(.vertical, 8)
      .background(RoundedRectangle(cornerRadius: 8).fill(configuration.isPressed ? Theme.raised : Theme.raised.opacity(0.6)))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
  }
}

/// A plain text link in the accent colour ("Start a session with another model →").
struct LinkButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 12)).foregroundStyle(Theme.accent).opacity(configuration.isPressed ? 0.7 : 1)
  }
}

/// Dark text field with the surface border, like the web inputs.
struct FieldStyle: ViewModifier {
  func body(content: Content) -> some View {
    content.textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(Theme.text)
      .padding(.horizontal, 12).padding(.vertical, 12)
      .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
  }
}

extension View {
  func field() -> some View { modifier(FieldStyle()) }
}
