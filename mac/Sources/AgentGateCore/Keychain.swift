import Foundation
import Security

public enum KeychainError: Error, Equatable, CustomStringConvertible {
  case failed(OSStatus)
  public var description: String {
    if case .failed(let status) = self { "The Keychain refused the request (status \(status))." } else { "" }
  }
}

/// One secret in the macOS Keychain. The app can save, check for and delete it; only the code that
/// calls the provider ever reads it, and it is never shown or logged.
public struct Keychain: Sendable {
  public var service: String
  public var account: String

  public init(service: String = "AGENTGATE Studio", account: String) {
    self.service = service
    self.account = account
  }

  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
     kSecAttrAccount as String: account]
  }

  public func save(_ secret: String) throws {
    try delete()
    var item = query
    item[kSecValueData as String] = Data(secret.utf8)
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw KeychainError.failed(status) }
  }

  public func read() throws -> String? {
    var item = query
    item[kSecReturnData as String] = true
    item[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    let status = SecItemCopyMatching(item as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.failed(status) }
    return String(decoding: data, as: UTF8.self)
  }

  public func delete() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.failed(status) }
  }
}
