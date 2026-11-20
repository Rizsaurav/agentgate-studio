import Foundation

/// Where AGENTGATE keeps its files on this Mac.
public enum AppPaths {
  public static var support: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("AGENTGATE", isDirectory: true)
  }

  public static var models: URL { support.appendingPathComponent("models", isDirectory: true) }
}
