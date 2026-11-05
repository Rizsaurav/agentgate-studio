import Foundation

/// The macOS sandbox (Seatbelt) the agent harness runs in. The operating system itself refuses any write outside
/// the allowed folders and any read of key and credential folders, whatever the agent or a command tries, and it
/// applies to every child process (shells, scripts, tools). This sits under the rules in ToolPolicy, not instead of them.
public enum AgentSandbox {
  public static let executable = "/usr/bin/sandbox-exec"

  /// Folders under the home folder that hold keys and credentials; never readable from the sandbox.
  static let secretFolders = [".ssh", ".gnupg", ".aws", ".kube", ".docker", "Library/Keychains", ".config/gh", ".netrc"]

  /// The profile: allow by default, deny all writes, then allow writes only to `writable`; deny reads of secrets.
  /// Without `network`, outbound connections are refused except to this Mac (the local engine and the harness).
  public static func profile(
    writable: [URL], home: URL = FileManager.default.homeDirectoryForCurrentUser, network: Bool = true
  ) -> String {
    func quoted(_ path: String) -> String {
      "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    // The kernel checks real paths (/private/var/...). URL.resolvingSymlinksInPath strips /private, so use realpath.
    let real = { (url: URL) -> String in
      guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
      defer { free(resolved) }
      return String(cString: resolved)
    }
    let allow = writable.map { "  (subpath \(quoted(real($0))))" }.joined(separator: "\n")
    let secrets = secretFolders.map { "  (subpath \(quoted(real(home.appendingPathComponent($0)))))" }.joined(separator: "\n")
    return """
      (version 1)
      (allow default)
      (deny file-write*)
      (allow file-write*
      \(allow)
        (literal "/dev/null") (literal "/dev/zero") (literal "/dev/tty") (regex #"^/dev/ttys[0-9]+$") (regex #"^/dev/fd/"))
      (deny file-read* file-write*
      \(secrets))
      """ + (network ? "" : """

      (deny network-outbound (remote ip "*:*"))
      (allow network-outbound (remote ip "localhost:*"))
      """)
  }

  /// What the harness may write: the project, its own state, and the system temporary folders.
  public static func writable(project: URL, agentHome: URL) -> [URL] {
    [project, agentHome, URL(fileURLWithPath: NSTemporaryDirectory()), URL(fileURLWithPath: "/private/tmp")]
  }
}
