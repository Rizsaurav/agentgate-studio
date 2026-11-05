import AppKit
import SwiftUI

/// Quiet charcoal content surfaces; system materials provide the navigation chrome.
enum Theme {
  static let bg = Color(hex: 0x141519)
  static let sidebar = Color(hex: 0x16171C)
  static let surface = Color(hex: 0x1C1D23)
  static let raised = Color(hex: 0x272830)
  static let line = Color(hex: 0x35363F)
  static let text = Color(hex: 0xEDEDF2)
  static let muted = Color(hex: 0xACADBA)
  static let accent = Color(hex: 0xC4AFF3)
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
    VStack(alignment: .leading, spacing: 8) {
      Eyebrow(eyebrow)
      Text(title).font(.system(size: 28, weight: .semibold)).tracking(-0.6).foregroundStyle(Theme.text)
      Text(detail).font(.system(size: 14)).foregroundStyle(Theme.muted).lineSpacing(4)
        .frame(maxWidth: 620, alignment: .leading)
    }
  }
}

/// Content stays on a quiet, readable surface rather than a second layer of glass.
struct Card<Content: View>: View {
  var padding: CGFloat = 24
  @ViewBuilder var content: Content
  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
  }
}

/// A square tile holding an icon, as used for empty states and list rows.
struct IconTile: View {
  let symbol: String
  var size: CGFloat = 46
  var body: some View {
    Image(systemName: symbol).font(.system(size: size * 0.4)).foregroundStyle(Theme.accent)
      .frame(width: size, height: size)
      .background(RoundedRectangle(cornerRadius: size * 0.28).fill(Theme.accent.opacity(0.07)))
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
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.accent.opacity(enabled ? 1 : 0.35)))
        .opacity(configuration.isPressed ? 0.85 : 1)
    }
  }
}

struct SubtleButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    SubtleButtonBody(configuration: configuration)
  }

  private struct SubtleButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    var body: some View {
      configuration.label.font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
        .padding(.horizontal, 13).padding(.vertical, 9)
        .studioGlass(radius: 11, interactive: enabled)
        .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
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

/// Glass is reserved for controls. Older systems use native material, and accessibility
/// preferences replace translucency with an opaque surface and a stronger edge.
private struct StudioGlass: ViewModifier {
  var radius: CGFloat
  var interactive: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast

  @ViewBuilder func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    if reduceTransparency || contrast == .increased {
      content.background(shape.fill(Theme.raised))
        .overlay(shape.strokeBorder(Theme.muted.opacity(0.6)))
    } else {
      // Keep the macOS 14 deployment target and older CI toolchains supported.
      #if compiler(>=6.2)
      if #available(macOS 26, *) {
        content.glassEffect(.regular.interactive(interactive && !reduceMotion), in: shape)
      } else {
        content.background(.regularMaterial, in: shape)
          .overlay(shape.strokeBorder(.white.opacity(0.1)))
      }
      #else
      content.background(.regularMaterial, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.1)))
      #endif
    }
  }
}

extension View {
  func studioGlass(radius: CGFloat = 16, interactive: Bool = false) -> some View {
    modifier(StudioGlass(radius: radius, interactive: interactive))
  }
}

/// A real behind-window material, so the sidebar responds to the desktop and window focus.
struct WindowBackdrop: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    if reduceTransparency || contrast == .increased {
      Theme.sidebar
    } else {
      SidebarMaterial().overlay(Theme.sidebar.opacity(0.25))
    }
  }
}

private struct SidebarMaterial: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .sidebar
    view.blendingMode = .behindWindow
    view.state = .followsWindowActiveState
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// AppKit-backed fields can discard a custom prompt's color. Draw a noninteractive
// hint explicitly so it stays readable on dark materials; retain its spoken hint.
extension View {
  func inputHint(_ text: String, when isEmpty: Bool) -> some View {
    overlay(alignment: .topLeading) {
      if isEmpty {
        Text(text).foregroundStyle(Theme.muted).lineLimit(1)
          .allowsHitTesting(false).accessibilityHidden(true)
      }
    }
    .accessibilityHint(text)
  }
}
