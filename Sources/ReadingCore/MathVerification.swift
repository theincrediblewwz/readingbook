import Foundation

public enum MathVerificationMode: String, Codable, Hashable, Sendable {
    case solveLinearSystem, checkRowSteps
}
public enum MathVerificationOrigin: String, Codable, Hashable, Sendable { case user, aiStructured }
public enum MathVerificationStatus: String, Codable, Hashable, Sendable { case verified, failed }
public enum MathRowOperationKind: String, Codable, Hashable, Sendable { case swap, scale, add }

/// Row numbers are one based in both the UI and the tool contract.
public struct MathRowOperation: Codable, Hashable, Sendable {
    public var kind: MathRowOperationKind
    public var targetRow: Int
    public var sourceRow: Int?
    public var factor: String?
    public init(kind: MathRowOperationKind, targetRow: Int, sourceRow: Int? = nil, factor: String? = nil) {
        self.kind = kind; self.targetRow = targetRow; self.sourceRow = sourceRow; self.factor = factor
    }
    public var label: String {
        switch kind {
        case .swap: return "R\(targetRow) ↔ R\(sourceRow ?? 0)"
        case .scale: return "R\(targetRow) ← (\(factor ?? "?")) R\(targetRow)"
        case .add: return "R\(targetRow) ← R\(targetRow) + (\(factor ?? "?")) R\(sourceRow ?? 0)"
        }
    }
}
public struct MathRowStep: Codable, Hashable, Sendable {
    public var operation: MathRowOperation
    public var expected: [[String]]
    public init(operation: MathRowOperation, expected: [[String]]) { self.operation = operation; self.expected = expected }
}
public struct MathVerificationRequest: Codable, Hashable, Sendable {
    public var title: String
    /// Original user text or exact source quote, retained independently from AI's transcription.
    public var input: String
    public var mode: MathVerificationMode
    public var matrix: [[String]]?
    public var steps: [MathRowStep]
    public var evidence: [Evidence]
    public var origin: MathVerificationOrigin
    public init(title: String = "数学核查", input: String, mode: MathVerificationMode = .solveLinearSystem,
                matrix: [[String]]? = nil, steps: [MathRowStep] = [], evidence: [Evidence] = [], origin: MathVerificationOrigin = .user) {
        self.title = title; self.input = input; self.mode = mode; self.matrix = matrix
        self.steps = steps; self.evidence = evidence; self.origin = origin
    }
}
public struct MathCellDifference: Codable, Hashable, Sendable {
    public var row: Int
    public var column: Int
    public var expected: String
    public var submitted: String
}
public struct MathVerifiedStep: Codable, Hashable, Sendable, Identifiable {
    public var id: Int { number }
    public var number: Int
    public var operation: MathRowOperation
    public var before: [[String]]
    /// Always host calculated, never the submitted result of a failed operation.
    public var after: [[String]]
    public var submitted: [[String]]?
    public var differences: [MathCellDifference]
    public var passed: Bool { differences.isEmpty }
}
public enum MathSolutionClassification: String, Codable, Hashable, Sendable { case unique, infinite, inconsistent }
public struct MathLinearSolution: Codable, Hashable, Sendable {
    public var classification: MathSolutionClassification
    public var coefficientRank: Int
    public var augmentedRank: Int
    /// One-based variable indices, in the same order as nullspaceBasis.
    public var freeVariables: [Int]
    public var particular: [String]
    public var nullspaceBasis: [[String]]
    /// Safe host-generated LaTeX, one expression per variable.
    public var expressions: [String]
    /// True only after exact A*p=b AND A*v=0 for every basis vector.
    public var substitutionVerified: Bool
}
public struct MathVerificationRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var title: String
    public var request: MathVerificationRequest
    public var normalizedMatrix: [[String]]
    public var resultMatrix: [[String]]
    public var steps: [MathVerifiedStep]
    public var status: MathVerificationStatus
    public var summary: String
    public var solution: MathLinearSolution?
    public var deletedAt: Date?
    /// Optional host attribution. AI arguments cannot supply these fields.
    public var workflowStepID: String? = nil
    public var workflowAttempt: Int? = nil
    public var scopeWarning: String {
        request.origin == .aiStructured
        ? "这是对 AI 转录的数字矩阵进行的精确运算核查；原文与结构化矩阵是否一致仍须对照，不能据此声称 OCR、书中推导或一般数学证明已获验证。"
        : "只核查输入的有理数矩阵与指定行变换；不验证一般符号、非线性方程或原书论证。"
    }
    public var markdown: String {
        var result = "# \(Self.escape(title))\n\n**\(Self.escape(summary))**\n\n> \(scopeWarning)\n\n## 实际核查的矩阵\n\n\(Self.matrixMarkdown(normalizedMatrix))\n"
        if !request.input.isEmpty {
            result += "\n## 保留的输入 / 原文\n\n" + request.input.split(separator: "\n", omittingEmptySubsequences: false).map { "> \(Self.escape(String($0)))" }.joined(separator: "\n") + "\n"
        }
        if let solution {
            result += "\n## 解与回代\n\n系数秩 \(solution.coefficientRank)，增广秩 \(solution.augmentedRank)。\n\n"
            if solution.classification == .inconsistent { result += "增广矩阵出现 $0 = 1$ 型矛盾行，无解。\n" }
            else {
                result += "$$\n\\begin{aligned}\n" + solution.expressions.joined(separator: " \\\\\n") + "\n\\end{aligned}\n$$\n\n"
                if !solution.freeVariables.isEmpty {
                    let parameters = solution.freeVariables.count == 1 ? "t_1" : "t_1,\\ldots,t_{\(solution.freeVariables.count)}"
                    result += "参数 $\(parameters)$ 可任取有理数或实数。\n\n"
                }
                result += solution.substitutionVerified ? "特解回代 $Ap=b$，每个自由方向回代 $Av=0$，全部以精确分数核验通过。\n" : "回代核验未通过。\n"
            }
        }
        result += "\n## 行变换记录\n\n"
        if steps.isEmpty { result += "输入已为所需形式，无需行变换。\n" }
        for step in steps {
            result += "\n### \(step.number). \(Self.escape(step.operation.label)) · \(step.passed ? "通过" : "不通过")\n\n计算前：\n\n\(Self.matrixMarkdown(step.before))\n\n宿主计算后：\n\n\(Self.matrixMarkdown(step.after))\n"
            for difference in step.differences {
                result += "\n- 第 \(difference.row) 行、第 \(difference.column) 列：应为 `\(difference.expected)`，提交的是 `\(difference.submitted)`。\n"
            }
            if !step.passed { result += "\n已在此处停止，后续提交步骤未核查。\n" }
        }
        if !request.evidence.isEmpty {
            result += "\n## 原文证据\n\n"
            for evidence in request.evidence { result += "- \(Self.escape(evidence.unitID))：\(Self.escape(evidence.quote))\n" }
        }
        return result
    }
    public static func matrixMarkdown(_ matrix: [[String]]) -> String {
        // Values reaching this method in a verified record are canonical fractions.
        "$$\n\\begin{bmatrix}\n" + matrix.map { $0.map(latexNumber).joined(separator: " & ") }.joined(separator: " \\\\\n") + "\n\\end{bmatrix}\n$$"
    }
    static func latexNumber(_ value: String) -> String {
        let parts = value.split(separator: "/")
        guard parts.count == 2 else { return value }
        return "\\frac{\(parts[0])}{\(parts[1])}"
    }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`").replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "$", with: "\\$")
    }
}

/// Bounded, exact arithmetic. An overflow is an unsupported input, never a rounded success.
/// Elementary row operations and RREF follow the standard contract documented at:
/// https://docs.sympy.org/latest/modules/matrices/matrices.html#sympy.matrices.matrixbase.MatrixBase.rref
public enum MathVerificationEngine {
    public static let maximumRows = 8
    public static let maximumColumns = 9
    public static let maximumSteps = 128

    public static func parseMatrix(_ text: String) throws -> [[String]] {
        try strings(parseMatrix(parseInput(text)))
    }

    public static func verify(_ request: MathVerificationRequest) throws -> MathVerificationRecord {
        guard request.title.count <= 200, request.input.utf8.count <= 32_768, request.steps.count <= maximumSteps,
              request.evidence.count <= 32, request.evidence.allSatisfy({ !$0.unitID.isEmpty && $0.unitID.count <= 128 && !$0.quote.isEmpty && $0.quote.count <= 32768 }) else {
            throw invalid("输入、来源或步骤超过核查上限。")
        }
        let matrix = try parseMatrix(request.matrix ?? parseInput(request.input))
        var record = MathVerificationRecord(id: UUID().uuidString, createdAt: Date(), title: request.title.isEmpty ? "数学核查" : request.title,
                                            request: request, normalizedMatrix: strings(matrix), resultMatrix: strings(matrix), steps: [],
                                            status: .verified, summary: "", solution: nil, deletedAt: nil)
        switch request.mode {
        case .solveLinearSystem:
            guard request.steps.isEmpty, matrix[0].count >= 2 else { throw invalid("求解时请只提交增广矩阵（最后一列为常数项），不要同时提交待核查步骤。") }
            let reduction = try rref(matrix)
            record.steps = reduction.steps; record.resultMatrix = strings(reduction.matrix)
            let solution = try solve(original: matrix, reduced: reduction.matrix, pivots: reduction.pivots)
            record.solution = solution
            switch solution.classification {
            case .unique: record.summary = "唯一解；精确回代通过"
            case .infinite: record.summary = "无穷多解，\(solution.freeVariables.count) 个自由参数；精确回代通过"
            case .inconsistent: record.summary = "无解；精确行变换得到矛盾行"
            }
        case .checkRowSteps:
            guard !request.steps.isEmpty else { throw invalid("逐步核查至少需要一条操作和它声称的完整结果矩阵。") }
            var current = matrix
            for (index, step) in request.steps.enumerated() {
                let submitted = try parseMatrix(step.expected)
                guard submitted.count == current.count, submitted[0].count == current[0].count else { throw invalid("第 \(index + 1) 步结果矩阵维度与输入不一致。") }
                let computed = try apply(step.operation, to: current)
                var differences: [MathCellDifference] = []
                for row in computed.indices { for column in computed[row].indices where computed[row][column] != submitted[row][column] {
                    differences.append(MathCellDifference(row: row + 1, column: column + 1, expected: computed[row][column].description, submitted: submitted[row][column].description))
                } }
                record.steps.append(MathVerifiedStep(number: index + 1, operation: step.operation, before: strings(current), after: strings(computed), submitted: strings(submitted), differences: differences))
                if !differences.isEmpty {
                    record.status = .failed; record.summary = "第 \(index + 1) 步不成立，\(differences.count) 个单元格不符；后续未核查"
                    // A failed submitted result must never become the next trusted input.
                    record.resultMatrix = strings(current)
                    return record
                }
                current = computed
            }
            record.resultMatrix = strings(current); record.summary = "\(record.steps.count) 条指定行变换精确核验通过"
        }
        return record
    }

    /// Only numeric row matrices are recognized. This deliberately does not guess equations or OCR LaTeX.
    public static func parseInput(_ input: String) throws -> [[String]] {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 32_768 else { throw invalid("请填写数字矩阵；每行一行、各项用空格或逗号分隔，最后一列为常数项。") }
        if value.hasPrefix("[") {
            // JSON numeric tokens are validated lexically, avoiding NSNumber/Double precision loss.
            var parser = NumericMatrixJSON(value)
            return try parser.parse()
        }
        let rows = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: ";", with: "\n").components(separatedBy: "\n")
        guard !rows.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) else { throw invalid("矩阵中不能有空行。") }
        return try rows.map { row in
            let values: [String]
            if row.contains(",") {
                values = row.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard !values.contains(where: \.isEmpty) else { throw invalid("矩阵存在空单元格。") }
            } else { values = row.split(whereSeparator: \.isWhitespace).map(String.init) }
            return values
        }
    }

    private static func parseMatrix(_ values: [[String]]) throws -> [[ExactRational]] {
        guard (1...maximumRows).contains(values.count), let columns = values.first?.count, (1...maximumColumns).contains(columns),
              values.allSatisfy({ $0.count == columns }) else { throw invalid("矩阵须为 1–8 行、1–9 列且每行等长；方程求解至少两列。") }
        return try values.map { try $0.map(ExactRational.parse) }
    }
    private static func strings(_ matrix: [[ExactRational]]) -> [[String]] { matrix.map { $0.map(\.description) } }

    private static func apply(_ op: MathRowOperation, to input: [[ExactRational]]) throws -> [[ExactRational]] {
        guard (1...input.count).contains(op.targetRow) else { throw invalid("目标行越界（行号从 1 开始）。") }
        var matrix = input; let target = op.targetRow - 1
        switch op.kind {
        case .swap:
            guard op.factor == nil, let source = op.sourceRow, (1...input.count).contains(source), source != op.targetRow else { throw invalid("交换必须指定两个不同的有效行，不能指定倍数。") }
            matrix.swapAt(target, source - 1)
        case .scale:
            guard op.sourceRow == nil, let text = op.factor else { throw invalid("倍乘只指定目标行和非零倍数。") }
            let factor = try ExactRational.parse(text)
            guard !factor.isZero else { throw invalid("零倍乘不保持行等价，拒绝执行。") }
            matrix[target] = try input[target].map { try $0.multiplied(by: factor) }
        case .add:
            guard let source = op.sourceRow, (1...input.count).contains(source), source != op.targetRow, let text = op.factor else { throw invalid("倍加必须指定两个不同的有效行和非零倍数。") }
            let factor = try ExactRational.parse(text)
            guard !factor.isZero else { throw invalid("零倍加没有改变矩阵，请省略该操作。") }
            matrix[target] = try input[target].indices.map { try input[target][$0].adding(input[source - 1][$0].multiplied(by: factor)) }
        }
        return matrix
    }
    private static func rref(_ input: [[ExactRational]]) throws -> (matrix: [[ExactRational]], pivots: [Int], steps: [MathVerifiedStep]) {
        var matrix = input, pivots: [Int] = [], steps: [MathVerifiedStep] = [], pivotRow = 0
        func append(_ op: MathRowOperation) throws {
            guard steps.count < maximumSteps else { throw invalid("精确消元超过 128 步，已停止。") }
            let after = try apply(op, to: matrix)
            steps.append(MathVerifiedStep(number: steps.count + 1, operation: op, before: strings(matrix), after: strings(after), submitted: nil, differences: []))
            matrix = after
        }
        // Include the augmented column, so a contradiction is also canonicalized.
        for column in input[0].indices {
            if pivotRow == matrix.count { break }
            guard let found = (pivotRow..<matrix.count).first(where: { !matrix[$0][column].isZero }) else { continue }
            if found != pivotRow { try append(MathRowOperation(kind: .swap, targetRow: pivotRow + 1, sourceRow: found + 1)) }
            if matrix[pivotRow][column] != .one {
                try append(MathRowOperation(kind: .scale, targetRow: pivotRow + 1, factor: matrix[pivotRow][column].reciprocal().description))
            }
            for row in matrix.indices where row != pivotRow && !matrix[row][column].isZero {
                try append(MathRowOperation(kind: .add, targetRow: row + 1, sourceRow: pivotRow + 1, factor: matrix[row][column].negated().description))
            }
            pivots.append(column); pivotRow += 1
        }
        return (matrix, pivots, steps)
    }
    private static func solve(original: [[ExactRational]], reduced: [[ExactRational]], pivots: [Int]) throws -> MathLinearSolution {
        let variables = original[0].count - 1, coefficientPivots = pivots.filter { $0 < variables }
        if pivots.contains(variables) {
            return MathLinearSolution(classification: .inconsistent, coefficientRank: coefficientPivots.count, augmentedRank: pivots.count,
                                      freeVariables: [], particular: [], nullspaceBasis: [], expressions: [], substitutionVerified: false)
        }
        let free = (0..<variables).filter { !pivots.contains($0) }
        var particular = Array(repeating: ExactRational.zero, count: variables)
        for (row, column) in coefficientPivots.enumerated() { particular[column] = reduced[row][variables] }
        var basis: [[ExactRational]] = []
        for column in free {
            var vector = Array(repeating: ExactRational.zero, count: variables); vector[column] = .one
            for (row, pivot) in coefficientPivots.enumerated() { vector[pivot] = try reduced[row][column].negated() }
            basis.append(vector)
        }
        func residual(_ vector: [ExactRational], homogeneous: Bool) throws -> Bool {
            for row in original {
                var sum = ExactRational.zero
                for column in 0..<variables { sum = try sum.adding(row[column].multiplied(by: vector[column])) }
                if sum != (homogeneous ? .zero : row[variables]) { return false }
            }
            return true
        }
        let particularVerified = try residual(particular, homogeneous: false)
        var basisVerified = true
        for vector in basis { if try !residual(vector, homogeneous: true) { basisVerified = false } }
        guard particularVerified && basisVerified else { throw invalid("内部精确回代失败，拒绝保存核验通过结果。") }
        let expressions = (0..<variables).map { variable -> String in
            var expression = particular[variable].isZero ? "" : MathVerificationRecord.latexNumber(particular[variable].description)
            for (index, vector) in basis.enumerated() where !vector[variable].isZero {
                let coefficient = vector[variable], negative = coefficient.numerator < 0
                let magnitude = ExactRational(numerator: abs(coefficient.numerator), denominator: coefficient.denominator)
                let term = (magnitude == .one ? "" : MathVerificationRecord.latexNumber(magnitude.description)) + "t_{\(index + 1)}"
                expression += expression.isEmpty ? (negative ? "-" : "") + term : (negative ? " - " : " + ") + term
            }
            return "x_{\(variable + 1)} &= " + (expression.isEmpty ? "0" : expression)
        }
        return MathLinearSolution(classification: free.isEmpty ? .unique : .infinite, coefficientRank: coefficientPivots.count, augmentedRank: pivots.count,
                                  freeVariables: free.map { $0 + 1 }, particular: particular.map(\.description), nullspaceBasis: strings(basis),
                                  expressions: expressions, substitutionVerified: true)
    }
    private static func invalid(_ message: String) -> ReadingError { .invalid("数学核查：" + message) }
}

private struct ExactRational: Equatable, CustomStringConvertible {
    var numerator: Int64
    var denominator: Int64
    static let zero = ExactRational(numerator: 0, denominator: 1)
    static let one = ExactRational(numerator: 1, denominator: 1)
    var isZero: Bool { numerator == 0 }
    var description: String { denominator == 1 ? String(numerator) : "\(numerator)/\(denominator)" }
    init(numerator: Int64, denominator: Int64) { self.numerator = numerator; self.denominator = denominator }
    static func make(_ n: Int64, _ d: Int64) throws -> Self {
        guard d != 0, n != Int64.min, d != Int64.min else { throw failure() }
        if n == 0 { return .zero }
        let divisor = gcd(abs(n), abs(d)), sign: Int64 = d < 0 ? -1 : 1
        return Self(numerator: try multiply(n / divisor, sign), denominator: abs(d) / divisor)
    }
    static func parse(_ raw: String) throws -> Self {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 40 else { throw failure("每项最多 40 字符。") }
        if text.contains("/") {
            let pieces = text.components(separatedBy: "/")
            guard pieces.count == 2 else { throw failure("仅支持整数、有限小数和 a/b 分数；暂不支持一般符号。") }
            return try make(integer(pieces[0]), integer(pieces[1]))
        }
        if text.contains(".") {
            let pieces = text.components(separatedBy: ".")
            guard pieces.count == 2, !pieces[0].isEmpty, (1...6).contains(pieces[1].count), pieces[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { throw failure("小数须有整数部分，且最多 6 位小数；不接受科学计数法。") }
            var power: Int64 = 1
            for _ in pieces[1] { power = try multiply(power, 10) }
            let whole = try integer(pieces[0]), fraction = try integer(pieces[1]), negative = pieces[0].hasPrefix("-")
            let scaled = try multiply(whole, power), signedFraction = negative ? -fraction : fraction
            return try make(add(scaled, signedFraction), power)
        }
        return try make(integer(text), 1)
    }
    /// Eighteen decimal digits bound each supplied integer. Generated arithmetic is
    /// additionally checked at every Int64 addition and multiplication.
    private static func integer(_ text: String) throws -> Int64 {
        let digits = text.hasPrefix("-") || text.hasPrefix("+") ? String(text.dropFirst()) : text
        guard (1...18).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }), let result = Int64(text), result != Int64.min else {
            throw failure("仅支持最多 18 位的整数或分数；无法解析符号、LaTeX、幂或非线性表达式。")
        }
        return result
    }
    func adding(_ other: Self) throws -> Self {
        let divisor = Self.gcd(denominator, other.denominator), leftScale = other.denominator / divisor, rightScale = denominator / divisor
        return try Self.make(Self.add(Self.multiply(numerator, leftScale), Self.multiply(other.numerator, rightScale)), Self.multiply(denominator, leftScale))
    }
    func multiplied(by other: Self) throws -> Self {
        let left = Self.gcd(abs(numerator), other.denominator), right = Self.gcd(abs(other.numerator), denominator)
        return try Self.make(Self.multiply(numerator / left, other.numerator / right), Self.multiply(denominator / right, other.denominator / left))
    }
    func reciprocal() throws -> Self { try Self.make(denominator, numerator) }
    func negated() throws -> Self { try Self.make(-numerator, denominator) }
    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var x = a, y = b
        while y != 0 { let remainder = x % y; x = y; y = remainder }
        return x == 0 ? 1 : x
    }
    private static func multiply(_ a: Int64, _ b: Int64) throws -> Int64 {
        let result = a.multipliedReportingOverflow(by: b)
        guard !result.overflow, result.partialValue != Int64.min else { throw failure() }
        return result.partialValue
    }
    private static func add(_ a: Int64, _ b: Int64) throws -> Int64 {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow, result.partialValue != Int64.min else { throw failure() }
        return result.partialValue
    }
    private static func failure(_ detail: String = "数值超出 Int64 精确范围或出现零分母；已停止，不会以浮点近似代替。") -> ReadingError { .invalid("数学核查：" + detail) }
}

/// A small lexical parser keeps JSON numbers exact and rejects booleans, NaN and exponent notation.
private struct NumericMatrixJSON {
    let bytes: [UInt8]
    var offset = 0
    init(_ value: String) { bytes = Array(value.utf8) }
    mutating func parse() throws -> [[String]] {
        try expect(91); var rows: [[String]] = []
        repeat {
            try expect(91); var row: [String] = []
            repeat {
                skip()
                if consume(34) {
                    let begin = offset
                    while offset < bytes.count && bytes[offset] != 34 { offset += 1 }
                    guard offset < bytes.count else { throw failure() }
                    row.append(String(decoding: bytes[begin..<offset], as: UTF8.self)); offset += 1
                } else {
                    let begin = offset
                    while offset < bytes.count && ([UInt8(45), 43, 46, 47].contains(bytes[offset]) || (48...57).contains(bytes[offset])) { offset += 1 }
                    guard begin < offset else { throw failure() }
                    let token = String(decoding: bytes[begin..<offset], as: UTF8.self)
                    guard token.range(of: "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?$", options: .regularExpression) != nil else { throw failure() }
                    row.append(token)
                }
                guard row.count <= MathVerificationEngine.maximumColumns else { throw failure() }
            } while consume(44)
            try expect(93); rows.append(row)
            guard rows.count <= MathVerificationEngine.maximumRows else { throw failure() }
        } while consume(44)
        try expect(93); skip(); guard offset == bytes.count else { throw failure() }
        return rows
    }
    mutating func skip() { while offset < bytes.count && [UInt8(9), 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
    mutating func consume(_ byte: UInt8) -> Bool { skip(); guard offset < bytes.count, bytes[offset] == byte else { return false }; offset += 1; return true }
    mutating func expect(_ byte: UInt8) throws { guard consume(byte) else { throw failure() } }
    func failure() -> ReadingError { .invalid("数学核查：JSON 须为有理数矩阵，如 [[\"1/2\",\"1\"],[\"2\",\"3\"]]；不接受空项、布尔值或一般符号。") }
}
