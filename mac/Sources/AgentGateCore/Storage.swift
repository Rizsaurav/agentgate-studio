import Foundation

/// What the app keeps on disk, for Settings (#113): sizes, and partial downloads that can be removed.
public enum Storage {
  /// Bytes used by every regular file under `folder`, counting what is allocated on disk.
  public static func size(of folder: URL) -> UInt64 {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
    guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else { return 0 }
    var total: UInt64 = 0
    for case let url as URL in walker {
      guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
      total += UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }
    return total
  }

  /// Partial downloads (`.part` files) left in the models folder by a stopped or failed install.
  public static func partialDownloads(in models: URL) -> [URL] {
    guard let walker = FileManager.default.enumerator(at: models, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "part" }.sorted { $0.path < $1.path }
  }

  /// Deletes the partial downloads in `models` and returns the bytes freed. Only `.part` files are touched.
  @discardableResult
  public static func removePartialDownloads(in models: URL) throws -> UInt64 {
    var freed: UInt64 = 0
    for part in partialDownloads(in: models) {
      freed += size(ofFile: part)
      try FileManager.default.removeItem(at: part)
    }
    return freed
  }

  static func size(ofFile url: URL) -> UInt64 {
    let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
    return UInt64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
  }
}
