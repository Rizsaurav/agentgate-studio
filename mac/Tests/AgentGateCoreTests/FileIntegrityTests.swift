import CryptoKit
import Foundation
import Testing

@testable import AgentGateCore

@Suite struct FileIntegrityTests {
  struct Fixture {
    let root: URL
    let store: ModelStore
    let model: InstalledModel

    init(bytes count: Int = 3 << 20) throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("verify-\(UUID().uuidString)")
      store = ModelStore(root: root)
      let data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) })
      let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      model = InstalledModel(
        id: "test-model", name: "Test", quant: .q4_K_M, file: "model.gguf", sha256: sha, bytes: UInt64(count),
        backend: .llamaCpp,
        config: RuntimeConfig(context: 8192, gpuLayers: 999, kvCacheType: "q8_0", flashAttention: true, threads: 4),
        readiness: .ready, reason: "", verifiedAt: Date())
      try FileManager.default.createDirectory(at: store.folder(model.id), withIntermediateDirectories: true)
      try data.write(to: store.fileURL(model))
      try store.save(model)
    }

    var file: URL { store.fileURL(model) }

    func flipByte(at offset: UInt64) throws {
      let handle = try FileHandle(forUpdating: file)
      defer { try? handle.close() }
      try handle.seek(toOffset: offset)
      let byte = try #require(try handle.read(upToCount: 1)).first!
      try handle.seek(toOffset: offset)
      try handle.write(contentsOf: Data([byte ^ 0x01]))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
  }

  @Test func anUntouchedFileIsIntact() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    #expect(try await FileIntegrityCheck(store: f.store).verify(f.model) == .intact)
  }

  @Test func oneFlippedByteOfTheSameSizeIsReportedAsDamaged() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    try f.flipByte(at: 2_000_000)
    let size = try FileManager.default.attributesOfItem(atPath: f.file.path)[.size] as? NSNumber
    #expect(size?.uint64Value == f.model.bytes)
    let result = try await FileIntegrityCheck(store: f.store).verify(f.model)
    #expect(result == .damaged(reason: "its checksum does not match"))
    #expect(result.isDamaged)
    #expect(result.message(for: f.model).contains("Reinstall"))
  }

  @Test func aFileOfAnotherSizeIsDamagedWithoutHashing() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let handle = try FileHandle(forWritingTo: f.file)
    try handle.truncate(atOffset: 1000)
    try handle.close()
    let result = try await FileIntegrityCheck(store: f.store).verify(f.model)
    guard case .damaged(let reason) = result else { Issue.record("expected damaged, got \(result)"); return }
    #expect(reason.contains("1000 bytes"))
  }

  @Test func aMissingFileIsReported() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    try FileManager.default.removeItem(at: f.file)
    #expect(try await FileIntegrityCheck(store: f.store).verify(f.model) == .missing)
  }

  @Test func progressRunsFromZeroToOne() async throws {
    let f = try Fixture(bytes: 20 << 20)
    defer { f.cleanup() }
    let seen = Seen()
    _ = try await FileIntegrityCheck(store: f.store).verify(f.model) { seen.add($0) }
    let values = seen.values
    #expect(values.last == 1)
    #expect(values == values.sorted())
    #expect(values.count > 1)
  }

  @Test func aCancelledCheckStops() async throws {
    let f = try Fixture(bytes: 64 << 20)
    defer { f.cleanup() }
    let task = Task { try await FileIntegrityCheck(store: f.store).verify(f.model) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test func normalLoadingDoesNotHash() throws {
    // The store's load check is existence only; hashing happens only through FileIntegrityCheck.
    let f = try Fixture()
    defer { f.cleanup() }
    try f.flipByte(at: 10)
    #expect(try f.store.load(f.model.id)?.id == f.model.id)
  }
}

final class Seen: @unchecked Sendable {
  private let lock = NSLock()
  private var list: [Double] = []
  func add(_ value: Double) { lock.lock(); list.append(value); lock.unlock() }
  var values: [Double] { lock.lock(); defer { lock.unlock() }; return list }
}
