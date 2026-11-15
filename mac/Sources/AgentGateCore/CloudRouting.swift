import Foundation

/// A cloud model the user can reach with a key they connected, with its price.
public struct CloudOffer: Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String
  public var providerId: String
  /// US dollars per million tokens.
  public var promptPerMillion: Double
  public var completionPerMillion: Double
  public var context: Int
  public var toolCalling: Bool

  public init(id: String, name: String, providerId: String, promptPerMillion: Double, completionPerMillion: Double,
              context: Int, toolCalling: Bool) {
    self.id = id
    self.name = name
    self.providerId = providerId
    self.promptPerMillion = promptPerMillion
    self.completionPerMillion = completionPerMillion
    self.context = context
    self.toolCalling = toolCalling
  }

  /// "$0.15 in · $0.60 out per million tokens".
  public var priceLabel: String {
    func dollars(_ value: Double) -> String { value < 1 ? String(format: "$%.2f", value) : String(format: "$%.1f", value) }
    return "\(dollars(promptPerMillion)) in · \(dollars(completionPerMillion)) out per million tokens"
  }

  /// A typical agent turn reads far more than it writes; weight prices that way to compare models.
  var blendedPrice: Double { (promptPerMillion * 3 + completionPerMillion) / 4 }
}

/// Reads a provider's model list into offers. Entries that are free, priced wrong or malformed are left out.
public enum CloudCatalog {
  /// OpenRouter's public `GET /api/v1/models`: prices are dollars per token, as strings.
  public static func parseOpenRouter(_ data: Data) -> [CloudOffer] {
    struct List: Decodable {
      struct Model: Decodable {
        struct Pricing: Decodable { var prompt: String?; var completion: String? }
        var id: String
        var name: String?
        var context_length: Int?
        var pricing: Pricing?
        var supported_parameters: [String]?
      }
      var data: [Model]
    }
    guard let list = try? JSONDecoder().decode(List.self, from: data) else { return [] }
    return list.data.compactMap { model in
      guard let prompt = model.pricing?.prompt.flatMap(Double.init),
            let completion = model.pricing?.completion.flatMap(Double.init),
            prompt > 0, completion > 0, prompt < 1, completion < 1,
            let context = model.context_length, context > 0,
            model.id.range(of: #"^[A-Za-z0-9._:/-]{1,120}$"#, options: .regularExpression) != nil else { return nil }
      return CloudOffer(
        id: model.id, name: String((model.name ?? model.id).prefix(80)), providerId: Providers.openRouter.id,
        promptPerMillion: prompt * 1_000_000, completionPerMillion: completion * 1_000_000, context: context,
        toolCalling: model.supported_parameters?.contains("tools") ?? false)
    }
  }

  public static let openRouterModels = URL(string: "https://openrouter.ai/api/v1/models")!

  /// Fetches OpenRouter's public list. Sends no key and nothing about the user or the task.
  public static func fetchOpenRouter(session: URLSession = .shared) async throws -> [CloudOffer] {
    var request = URLRequest(url: openRouterModels, timeoutInterval: 15)
    request.httpMethod = "GET"
    let (data, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
    return parseOpenRouter(data)
  }
}

/// Where a task should run: local first, cloud only when this Mac cannot do it, and only if the user picks it.
public enum RouteAdvice: Sendable, Equatable {
  /// A local model can do this. Cloud is not offered.
  case local
  /// No installed or installable local model meets the task's needs. The offers are suggestions to click; nothing
  /// is sent anywhere until the user chooses one.
  case cloudSuggested(reason: String, offers: [CloudOffer])
}

/// Decides before any answer exists, from the task's needs and what fits this Mac. Pure and deterministic.
public enum TaskRouter {
  /// Below this, a local model is too small for a task that asks for the best quality.
  public static let qualityParameters = 7e9
  /// Long inputs need at least this much context.
  public static let longContext = 32_768

  public static func advise(
    needs: TaskNeeds, local: [ModelSuggestion], connected offers: [CloudOffer], limit: Int = 3
  ) -> RouteAdvice {
    guard let reason = shortfall(needs: needs, local: local) else { return .local }
    let fitting = offers
      .filter { !needs.tools || $0.toolCalling }
      .filter { !needs.longContext || $0.context >= longContext }
      .sorted { $0.blendedPrice != $1.blendedPrice ? $0.blendedPrice < $1.blendedPrice : $0.id < $1.id }
    // The cheapest models are often the weakest; for quality work skip the bottom of the list.
    let chosen = needs.priority == .quality && fitting.count > limit ? Array(fitting.dropFirst(fitting.count / 3)) : fitting
    return .cloudSuggested(reason: reason, offers: Array(chosen.prefix(limit)))
  }

  /// Why no local model is enough, or nil when one is.
  public static func shortfall(needs: TaskNeeds, local: [ModelSuggestion]) -> String? {
    guard let best = local.first else {
      return needs.tools
        ? "No model that calls tools reliably fits this Mac."
        : "No local model fits this Mac."
    }
    if needs.longContext, local.allSatisfy({ context($0) < longContext }) {
      return "The task needs long inputs, and the longest context that fits this Mac is \(context(best) / 1024)K."
    }
    if needs.priority == .quality, local.allSatisfy({ parameters($0) < qualityParameters }) {
      return "The task asks for the best quality, and the largest model that fits this Mac is about \(Int((parameters(best) / 1e9).rounded()))B parameters."
    }
    return nil
  }

  static func context(_ s: ModelSuggestion) -> Int { s.context }
  static func parameters(_ s: ModelSuggestion) -> Double { s.parameters }
}
