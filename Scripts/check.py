#!/usr/bin/env python3
"""Run the exact XCTest cases with Command Line Tools, even when XCTest is absent."""
from pathlib import Path
import tempfile, subprocess, sys
root=Path(__file__).resolve().parents[1]
helpers=r'''
import Foundation
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) rethrows { let x = try a(), y = try b(); precondition(x == y, "Values differ at \(file):\(line)") }
func XCTAssertTrue(_ a: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) { precondition(a(), "Expected true at \(file):\(line)") }
func XCTAssertFalse(_ a: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) { precondition(!a(), "Expected false at \(file):\(line)") }
func XCTAssertNil<T>(_ a: @autoclosure () throws -> T?) rethrows { let x = try a(); precondition(x == nil) }
func XCTAssertNotNil<T>(_ a: @autoclosure () -> T?) { precondition(a() != nil) }
func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T) { precondition(a > b) }
func XCTAssertLessThanOrEqual<T: Comparable>(_ a: T, _ b: T) { precondition(a <= b) }
func XCTAssertThrowsError<T>(_ a: @autoclosure () throws -> T) { do { _ = try a(); fatalError("Expected error") } catch {} }
func XCTUnwrap<T>(_ a: T?) throws -> T { guard let a else { throw RelayError.message("Expected non-nil") }; return a }
func XCTFail(_ message: String) { fatalError(message) }
func XCTSkip(_ message: String) -> Error { RelayError.message(message) }
@main struct Runner {
 @MainActor static func main() async throws {
  setbuf(stdout, nil)
  let p = ProtocolTests()
  try p.testChunkRoundTripWithUnicodeAndReplay()
  try p.testMalformedChunkFailsClosed()
  try p.testAcksAreScopedToClientAndStream()
  try p.testPartialChunkAckKeepsRemainingFrames()
  try p.testQueueOverflowIsAtomic()
  p.testSecretsAndLocalVerificationAreNeverProxied()
  try await p.testDisconnectedPeerGetsResponseAndPairingIsNotRequired()
  try p.testProfileImportAndRejectAmbiguousAccount()
  try p.testJSONRetainsNullAndBoolean()
  try p.testPrivateIdentityPersistsAndStaysSignedOut()
  print("PASS: 10 framing, identity, isolation, and disconnect tests")
  let r = RuntimeTests()
  try await r.testMissingSocketFailsWithoutHanging()
  print("PASS: missing runtime fails promptly")
  try await r.testTwoClientsShareRealCodexRuntime()
  print("PASS: two independent clients share the same real Codex thread")
  try await r.testGatewayRecoversAfterRuntimeRestart()
  print("PASS: gateway recovers after isolated runtime restart")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='relay-checks-') as directory:
 d=Path(directory);sources=[]
 for source in (root/'Tests/RelayCoreTests').glob('*.swift'):
  text=source.read_text().replace('import XCTest','import Foundation').replace('@testable import RelayCore','').replace(': XCTestCase','')
  # Standalone assertion helpers use rethrows; XCTest uses a nonthrowing autoclosure wrapper.
  text=text.replace('XCTAssertEqual(try ', 'try XCTAssertEqual(try ').replace('XCTAssertNil(try ', 'try XCTAssertNil(try ')
  target=d/source.name;target.write_text(text);sources.append(str(target))
 runner=d/'Runner.swift';runner.write_text(helpers)
 command=['swiftc','-swift-version','5','-parse-as-library','-o',str(d/'checks')]+[str(p) for p in (root/'Sources/RelayCore').glob('*.swift')]+sources+[str(runner)]
 subprocess.run(command,check=True)
 subprocess.run([str(d/'checks')],check=True,timeout=90)
