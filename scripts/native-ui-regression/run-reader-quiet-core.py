#!/usr/bin/env python3
"""Run the current test bodies as standalone assertions on CLT-only Macs.

This is explicitly not XCTest. CI runs the original file with real XCTest.
"""
from pathlib import Path
import argparse, hashlib, json, os, re, subprocess
R = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(); p.add_argument('--bin-dir', type=Path, required=True); p.add_argument('--output', type=Path, required=True)
p.add_argument('--test-file', type=Path, default=Path('Tests/ReadingCoreTests/ReaderQuietTests.swift'))
p.add_argument('--test-class', default='ReaderQuietTests')
a = p.parse_args(); b, out = a.bin_dir.resolve(), a.output.resolve()
assert b.is_relative_to(R) and out.is_relative_to(R) and not out.exists()
out.mkdir(parents=True); (out / 'tmp').mkdir()
source = (R / a.test_file).resolve()
assert source.is_relative_to(R / 'Tests/ReadingCoreTests') and a.test_class.isidentifier()
text = source.read_text()
cases = re.findall(r'func (test\w+)\(\)([^\{]*)\{', text)
shim = r'''
struct LocalFailure: Error {}
class XCTestCase {}
var assertionCount = 0
var failures: [String] = []
func check(_ value: Bool, _ message: String, _ file: StaticString, _ line: UInt) { assertionCount += 1; if !value { failures.append("\(file):\(line) \(message)") } }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { check(a == b, "equal: \(a) / \(b) " + message, file, line) }
func XCTAssertNotEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { check(a != b, "not equal " + message, file, line) }
func XCTAssertEqual<T: BinaryFloatingPoint>(_ a: T, _ b: T, accuracy: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { check(abs(a-b) <= accuracy, "accuracy " + message, file, line) }
func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { check(a > b, "greater " + message, file, line) }
func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { check(a >= b, "greater equal " + message, file, line) }
func XCTAssertLessThan<T: Comparable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { check(a < b, "less " + message, file, line) }
func XCTAssertLessThanOrEqual<T: Comparable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { check(a <= b, "less equal " + message, file, line) }
func XCTAssertTrue(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { check(value, "true " + message, file, line) }
func XCTAssertFalse(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { check(!value, "false " + message, file, line) }
func XCTAssertNil<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { check(value == nil, "nil " + message, file, line) }
func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) { check(false, message, file, line) }
func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T { guard let value else { check(false, "unwrap", file, line); throw LocalFailure() }; return value }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { do { _ = try expression(); check(false, "expected throw " + message, file, line) } catch { check(true, message, file, line) } }
'''
# Keep fixture paths anchored to the repository rather than the generated file.
body = text.replace('import XCTest\n', '').replace('#filePath', json.dumps(str(source)))
names = [name for name, _ in cases]
calls = '\n'.join('executed.append(' + json.dumps(name) + '); do { ' + ('try await' if 'async' in signature else 'try') + ' tests.' + name + '(); completed.append(' + json.dumps(name) + ') } catch { failures.append(' + json.dumps(name + ': ') + ' + String(describing: error)) }' for name, signature in cases)
main = '''
@main enum LocalQuietCoreMain {
    static func main() async {
        var executed: [String] = [], completed: [String] = []
        let tests = TEST_CLASS()
        %s
        let value: [String: Any] = ["runner": "standalone assertions, not XCTest", "status": failures.isEmpty ? "passed" : "failed", "declaredCases": %s, "executedCases": executed, "completedCases": completed, "assertions": assertionCount, "failures": failures]
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted,.sortedKeys]).write(to: output)
        exit(failures.isEmpty ? 0 : 1)
    }
}
''' % (calls, '[' + ','.join(json.dumps(name) for name in names) + ']')
main = main.replace('TEST_CLASS', a.test_class)
generated = out / 'StandaloneTests.swift'; generated.write_text(body + shim + main)
work = R / '.build/quiet-core-probe'; work.mkdir(exist_ok=True)
objects = sorted((b / 'ReadingCore.build').glob('*.swift.o'))
assert objects
swift, clang = R / '.build/shared-module-cache/swift', R / '.build/shared-module-cache/clang'
env = dict(os.environ, TMPDIR=str(out / 'tmp'))
binary = work / 'quiet-core-probe'
cmd = ['swiftc', '-O', '-parse-as-library', '-I', str(b / 'Modules'), '-module-cache-path', str(swift), '-Xcc', '-fmodules-cache-path=' + str(clang), str(generated), *map(str, objects), '-o', str(binary)]
with (out / 'compile.log').open('x') as log: compiled = subprocess.run(cmd, cwd=R, env=env, stdout=log, stderr=subprocess.STDOUT)
assert compiled.returncode == 0, 'See ' + str(out / 'compile.log')
with (out / 'runtime.log').open('x') as log: run = subprocess.run([str(binary), str(out / 'result.json')], cwd=R, env=env, stdout=log, stderr=subprocess.STDOUT)
sha = lambda f: hashlib.sha256(f.read_bytes()).hexdigest()
(out / 'manifest.json').write_text(json.dumps(dict(testSourceSHA256=sha(source), generatedSourceSHA256=sha(generated), binarySHA256=sha(binary), objects=[dict(path=str(f.relative_to(R)), sha256=sha(f)) for f in objects]), indent=2) + '\n')
print((out / 'result.json').read_text()); raise SystemExit(run.returncode)
