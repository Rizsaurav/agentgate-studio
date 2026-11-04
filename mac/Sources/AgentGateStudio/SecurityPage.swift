import AgentGateCore
import SwiftUI

struct SecurityPage: View {
  @State private var tab = 0

  var body: some View {
    PageScroll {
      VStack(alignment: .leading, spacing: 28) {
        PageHeading(
          eyebrow: "Inspect. Verify. Improve.", title: "Security & Verification",
          detail: "Enforced protections, attributable findings, and repeatable tests. These checks reduce risk; they do not guarantee protection from every attack.")
        HStack(spacing: 22) {
          HStack(spacing: 10) {
            Image(systemName: "checkmark.shield").foregroundStyle(Theme.muted)
            Text("Model engine").font(.system(size: 13))
            StatusPill(text: "Local only", tone: .ok)
          }
          HStack(spacing: 10) {
            Image(systemName: "shield").foregroundStyle(Theme.muted)
            Text("LLM Guard scanner").font(.system(size: 13))
            StatusPill(text: "Not bundled yet", tone: .pending)
          }
          HStack(spacing: 10) {
            Image(systemName: "key").foregroundStyle(Theme.muted)
            Text("Agent tools").font(.system(size: 13))
            StatusPill(text: "Disabled", tone: .neutral)
          }
        }
        VStack(spacing: 0) {
          HStack(spacing: 26) {
            TabButton(title: "Guardrails & findings", symbol: "checkmark.shield", selected: tab == 0) { tab = 0 }
            TabButton(title: "Evaluations", symbol: "waveform.path.ecg", selected: tab == 1) { tab = 1 }
            Spacer()
          }
          Rectangle().fill(Theme.line).frame(height: 1)
        }
        if tab == 0 { guardrails } else { evaluations }
      }
    }
  }

  private var guardrails: some View {
    VStack(alignment: .leading, spacing: 34) {
      HStack(alignment: .top, spacing: 36) {
        Guardrail(symbol: "lock.shield", title: "Local engine",
                  text: "The bundled engine listens on this Mac only and refuses requests without the per-launch key.")
        Guardrail(symbol: "checkmark.seal", title: "Verified downloads",
                  text: "Every model file is checked against its published checksum before it is loaded.")
        Guardrail(symbol: "key", title: "Restricted capabilities",
                  text: "No shell or filesystem tools are granted to the model.")
      }
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text("Security findings").font(.system(size: 16, weight: .semibold))
          Spacer()
          Text("0 recorded").font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        Card {
          VStack(spacing: 10) {
            IconTile(symbol: "checkmark.shield", size: 58)
            Text("No findings recorded").font(.system(size: 15, weight: .semibold))
            Text("Input, retrieval and answer scanning run in the harness. Findings appear here once it runs inside the app.")
              .font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 360)
          }
          .frame(maxWidth: .infinity).padding(.vertical, 24)
        }
      }
    }
  }

  private var evaluations: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("A version-controlled Promptfoo suite runs the application's real pipeline against functional and security cases. The same suite runs in GitHub Actions on every change; running it from the Mac app arrives with the bundled harness.")
        .font(.system(size: 14)).foregroundStyle(Theme.muted).lineSpacing(4).frame(maxWidth: 680, alignment: .leading)
      VStack(alignment: .leading, spacing: 12) {
        Text("Recent runs").font(.system(size: 16, weight: .semibold))
        Text("No evaluations have run on this Mac yet.").font(.system(size: 14)).foregroundStyle(Theme.muted)
          .padding(28).frame(maxWidth: .infinity, alignment: .leading)
          .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4])))
      }
    }
  }
}

private struct TabButton: View {
  let title: String
  let symbol: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 12) {
        Label(title, systemImage: symbol).font(.system(size: 13)).foregroundStyle(selected ? Theme.text : Theme.muted)
        Rectangle().fill(selected ? Theme.accent : .clear).frame(height: 2)
      }
      .fixedSize(horizontal: true, vertical: false)
    }
    .buttonStyle(.plain)
  }
}

private struct Guardrail: View {
  let symbol: String
  let title: String
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.accent)
      Text(title).font(.system(size: 13, weight: .semibold))
      Text(text).font(.system(size: 13)).foregroundStyle(Theme.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
