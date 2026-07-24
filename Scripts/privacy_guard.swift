#!/usr/bin/xcrun swift

import CryptoKit
import Darwin
import Foundation

private let maximumScannableFileSize = 25 * 1024 * 1024
private let binaryAllowlistPath = "Scripts/privacy_binary_allowlist.txt"
private let zeroObjectID = String(repeating: "0", count: 40)

private struct CommandResult {
    let status: Int32
    let output: Data
}

private struct Finding: Hashable {
    let rule: String
    let path: String
}

private struct BinaryApproval: Hashable {
    let hash: String
    let path: String
}

private enum SourceKind {
    case staged
    case worktree
    case revision(String)
}

private struct RepositorySource {
    let kind: SourceKind
    let root: URL

    func paths() throws -> [String] {
        let data: Data

        switch kind {
        case .staged:
            data = try runGit(
                ["diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"],
                at: root
            ).output
        case .worktree:
            data = try runGit(
                ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                at: root
            ).output
        case let .revision(revision):
            data = try runGit(
                ["ls-tree", "-r", "-z", "--name-only", revision],
                at: root
            ).output
        }

        return nulSeparatedStrings(from: data)
    }

    func data(for path: String) throws -> Data? {
        switch kind {
        case .staged:
            return try gitBlobData(specifier: ":\(path)")
        case .worktree:
            let fileURL = root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return nil
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)
                return Data(destination.utf8)
            }

            return try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        case let .revision(revision):
            return try gitBlobData(specifier: "\(revision):\(path)")
        }
    }

    func displayPath(for path: String) -> String {
        switch kind {
        case .staged, .worktree:
            return path
        case let .revision(revision):
            return "\(revision.prefix(12)):\(path)"
        }
    }

    private func gitBlobData(specifier: String) throws -> Data? {
        let result = try runGit(["show", specifier], at: root, requireSuccess: false)
        return result.status == 0 ? result.output : nil
    }
}

private final class PrivacyScanner {
    private(set) var findings = Set<Finding>()
    private(set) var scannedFileCount = 0
    private var binaryApprovals = Set<BinaryApproval>()

    private let emailRegex = try! NSRegularExpression(
        pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
        options: [.caseInsensitive]
    )
    private let personalPathRegexes = [
        try! NSRegularExpression(
            pattern: #"(?:file://)?/(?:Users|home)/[A-Za-z0-9._-]+(?:/|\b)"#,
            options: [.caseInsensitive]
        ),
        try! NSRegularExpression(
            pattern: #"[A-Z]:\\Users\\[^\\\s"'<>]+"#,
            options: [.caseInsensitive]
        )
    ]
    private let chineseIDRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z])[1-9][0-9]{16}[0-9Xx](?![0-9A-Za-z])"#
    )
    private let loggingCallRegex: NSRegularExpression
    private let sensitiveLogTokenRegex = try! NSRegularExpression(
        pattern: #"\b(?:recognizedText|recognizedString|ocrText|documentText|rawText|inputText|textItems?|candidate|observation|topCandidates|request\.results|documentContents?|sourceURL)\b"#,
        options: [.caseInsensitive]
    )
    private let metadataIdentityRegex = try! NSRegularExpression(
        pattern: #"(?is)(?:/Author|/Title|/Subject|/Keywords)\s*\(\s*[^)\s][^)]*\)|<dc:creator[^>]*>.*?<rdf:li[^>]*>\s*[^<\s][^<]*|<(?:cp:lastModifiedBy|Company|Manager|meta:initial-creator|meta:printed-by)[^>]*>\s*[^<\s][^<]*"#
    )
    private let forbiddenRepositoryPathRegex: NSRegularExpression
    private let privateMarkerRegex: NSRegularExpression

    private let knownBinaryExtensions: Set<String> = [
        "pdf", "doc", "docx", "rtf", "rtfd", "pages",
        "xls", "xlsx", "ppt", "pptx", "key", "numbers",
        "jpg", "jpeg", "png", "heic", "tif", "tiff"
    ]
    private let zipDocumentExtensions: Set<String> = [
        "docx", "xlsx", "pptx", "pages", "key", "numbers"
    ]
    private let opaqueLegacyExtensions: Set<String> = [
        "doc", "xls", "ppt", "rtfd"
    ]

    init() {
        let forbiddenRepositoryRoots = [
            "Private" + "Fixtures",
            "Do" + "cs"
        ]
        let forbiddenRootPattern = forbiddenRepositoryRoots
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        forbiddenRepositoryPathRegex = try! NSRegularExpression(
            pattern: "(?:\(forbiddenRootPattern))" + #"/[^\s"'`<>/]+(?:/[^\s"'`<>]+)*"#,
            options: [.caseInsensitive]
        )

        let markers = [
            "run_" + "private_ocr_regression",
            "split_name_real_" + "private",
            "real_" + "pri" + "vate",
            "pri" + "vate_real"
        ]
        privateMarkerRegex = try! NSRegularExpression(
            pattern: markers.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|"),
            options: [.caseInsensitive]
        )

        let loggingFunctionNames = [
            "pr" + "int",
            "debug" + "Print",
            "du" + "mp",
            "NS" + "Log",
            "os_" + "log",
            "os_" + "log_debug",
            "os_" + "log_info",
            "os_" + "log_error",
            "os_" + "log_fault"
        ]
        let functionPattern = #"\b(?:"#
            + loggingFunctionNames
                .map(NSRegularExpression.escapedPattern(for:))
                .joined(separator: "|")
            + #")\s*\("#
        let loggerPattern = #"\b[A-Za-z_][A-Za-z0-9_]*(?:logger|log)[A-Za-z0-9_]*\s*\.\s*(?:trace|debug|info|notice|warning|error|critical|log)\s*\("#
        loggingCallRegex = try! NSRegularExpression(
            pattern: functionPattern + "|" + loggerPattern,
            options: [.caseInsensitive]
        )
    }

    func scan(source: RepositorySource) throws {
        let paths = try source.paths()
        binaryApprovals = try approvals(in: source)

        for path in paths {
            guard let data = try source.data(for: path) else {
                continue
            }

            scannedFileCount += 1
            scan(
                data: data,
                repositoryPath: path,
                displayPath: source.displayPath(for: path)
            )
        }
    }

    func checkWorkingIdentity(at root: URL) throws {
        try checkIdentity(
            result: runGit(["var", "GIT_AUTHOR_IDENT"], at: root).output,
            label: "working-author"
        )
        try checkIdentity(
            result: runGit(["var", "GIT_COMMITTER_IDENT"], at: root).output,
            label: "working-committer"
        )
    }

    func checkCommitIdentity(_ revision: String, at root: URL) throws {
        let result = try runGit(
            ["show", "-s", "--format=%ae%x00%ce", revision],
            at: root
        ).output
        let emails = nulSeparatedStrings(from: result)

        if emails.count < 2 {
            add(rule: "commit-email-unreadable", path: "\(revision.prefix(12)):<commit-metadata>")
            return
        }

        if !isAllowedCommitEmail(emails[0]) {
            add(rule: "personal-commit-email", path: "\(revision.prefix(12)):<author-email>")
        }
        if !isAllowedCommitEmail(emails[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
            add(rule: "personal-commit-email", path: "\(revision.prefix(12)):<committer-email>")
        }
    }

    func merge(_ other: PrivacyScanner) {
        findings.formUnion(other.findings)
        scannedFileCount += other.scannedFileCount
    }

    private func approvals(in source: RepositorySource) throws -> Set<BinaryApproval> {
        guard let data = try source.data(for: binaryAllowlistPath),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        let entryRegex = try! NSRegularExpression(
            pattern: #"^([0-9a-fA-F]{64})[ \t]+(.+)$"#
        )
        var approvals = Set<BinaryApproval>()

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = entryRegex.firstMatch(in: line, range: range),
                  let hashRange = Range(match.range(at: 1), in: line),
                  let pathRange = Range(match.range(at: 2), in: line) else {
                add(
                    rule: "invalid-binary-allowlist",
                    path: "\(source.displayPath(for: binaryAllowlistPath)):\(index + 1)"
                )
                continue
            }

            approvals.insert(
                BinaryApproval(
                    hash: String(line[hashRange]).lowercased(),
                    path: String(line[pathRange])
                )
            )
        }

        return approvals
    }

    private func scan(data: Data, repositoryPath: String, displayPath: String) {
        scanText(String(decoding: Data(repositoryPath.utf8), as: UTF8.self), path: displayPath)

        guard data.count <= maximumScannableFileSize else {
            add(rule: "file-too-large-to-scan", path: displayPath)
            return
        }

        let fileExtension = URL(fileURLWithPath: repositoryPath).pathExtension.lowercased()
        let containsNUL = data.contains(0)

        if knownBinaryExtensions.contains(fileExtension) || containsNUL {
            scanBinary(
                data: data,
                repositoryPath: repositoryPath,
                displayPath: displayPath,
                fileExtension: fileExtension
            )
            return
        }

        if let text = decodedText(from: data) {
            scanText(text, path: displayPath)
        }
    }

    private func scanText(_ text: String, path: String, checkLogging: Bool = true) {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)

        for match in chineseIDRegex.matches(in: text, range: fullRange) {
            guard let range = Range(match.range, in: text) else {
                continue
            }
            if looksLikeChineseIdentityNumber(String(text[range])) {
                add(rule: "chinese-identity-number", path: path)
                break
            }
        }

        for match in emailRegex.matches(in: text, range: fullRange) {
            guard let range = Range(match.range, in: text) else {
                continue
            }
            if !isAllowedRepositoryEmail(String(text[range])) {
                add(rule: "personal-email", path: path)
                break
            }
        }

        if personalPathRegexes.contains(where: {
            $0.firstMatch(in: text, range: fullRange) != nil
        }) {
            add(rule: "personal-absolute-path", path: path)
        }

        if forbiddenRepositoryPathRegex.firstMatch(in: text, range: fullRange) != nil
            || privateMarkerRegex.firstMatch(in: text, range: fullRange) != nil {
            add(rule: "forbidden-repository-path", path: path)
        }

        if checkLogging {
            scanLogging(in: text, path: path)
        }
    }

    private func scanLogging(in text: String, path: String) {
        let supportedExtensions = Set(["swift", "m", "mm"])
        guard supportedExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else {
            return
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let calls = loggingCallRegex.matches(in: text, range: fullRange)
        guard !calls.isEmpty else {
            return
        }

        if path.lowercased().contains("ocr") {
            add(rule: "logging-in-ocr-source", path: path)
            return
        }

        let nsText = text as NSString
        for call in calls {
            let location = call.range.location
            let length = min(800, nsText.length - location)
            let window = nsText.substring(with: NSRange(location: location, length: length))
            let windowRange = NSRange(window.startIndex..<window.endIndex, in: window)

            if sensitiveLogTokenRegex.firstMatch(in: window, range: windowRange) != nil {
                add(rule: "sensitive-content-logging", path: path)
                return
            }
        }
    }

    private func scanBinary(
        data: Data,
        repositoryPath: String,
        displayPath: String,
        fileExtension: String
    ) {
        let rawText = String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        scanText(rawText, path: displayPath, checkLogging: false)
        scanMetadataText(rawText, path: displayPath)

        if opaqueLegacyExtensions.contains(fileExtension) {
            add(rule: "opaque-binary-document", path: displayPath)
        } else if fileExtension == "pdf", rawText.contains("/Encrypt") {
            add(rule: "encrypted-document-metadata-unreadable", path: displayPath)
        } else if knownBinaryExtensions.contains(fileExtension) {
            inspectBinaryMetadata(
                data: data,
                displayPath: displayPath,
                fileExtension: fileExtension
            )
        } else {
            add(rule: "unsupported-binary-format", path: displayPath)
        }

        let approval = BinaryApproval(
            hash: sha256Hex(data),
            path: repositoryPath
        )
        if !binaryApprovals.contains(approval) {
            add(rule: "binary-review-required", path: displayPath)
        }
    }

    private func inspectBinaryMetadata(
        data: Data,
        displayPath: String,
        fileExtension: String
    ) {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("medmask-privacy-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
            defer {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }

            let temporaryFile = temporaryDirectory
                .appendingPathComponent("candidate")
                .appendingPathExtension(fileExtension)
            try data.write(to: temporaryFile, options: [.atomic])

            let metadataKeys = [
                "kMDItemAuthors",
                "kMDItemContributors",
                "kMDItemOrganizations",
                "kMDItemWhereFroms"
            ]

            for key in metadataKeys {
                let result = try runCommand(
                    executable: "/usr/bin/mdls",
                    arguments: ["-raw", "-name", key, temporaryFile.path],
                    requireSuccess: false
                )
                guard result.status == 0 else {
                    continue
                }

                let value = String(decoding: result.output, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, value != "(null)", value != "null", value != "()" {
                    add(rule: "document-identity-metadata", path: displayPath)
                }
                scanText(value, path: displayPath, checkLogging: false)
            }

            if zipDocumentExtensions.contains(fileExtension) {
                inspectZipMetadata(at: temporaryFile, displayPath: displayPath)
            }
        } catch {
            add(rule: "document-metadata-unreadable", path: displayPath)
        }
    }

    private func inspectZipMetadata(at fileURL: URL, displayPath: String) {
        do {
            let listing = try runCommand(
                executable: "/usr/bin/unzip",
                arguments: ["-Z1", fileURL.path],
                requireSuccess: false
            )
            guard listing.status == 0 else {
                add(rule: "document-metadata-unreadable", path: displayPath)
                return
            }

            let entries = String(decoding: listing.output, as: UTF8.self)
                .split(separator: "\n")
                .map(String.init)
                .filter(isMetadataArchiveEntry)

            for entry in entries.prefix(50) {
                let extracted = try runCommand(
                    executable: "/usr/bin/unzip",
                    arguments: ["-p", fileURL.path, entry],
                    requireSuccess: false
                )
                guard extracted.status == 0, extracted.output.count <= 2 * 1024 * 1024 else {
                    add(rule: "document-metadata-unreadable", path: displayPath)
                    continue
                }

                let text = decodedText(from: extracted.output)
                    ?? String(data: extracted.output, encoding: .isoLatin1)
                    ?? ""
                scanText(text, path: displayPath, checkLogging: false)
                scanMetadataText(text, path: displayPath)
            }
        } catch {
            add(rule: "document-metadata-unreadable", path: displayPath)
        }
    }

    private func isMetadataArchiveEntry(_ entry: String) -> Bool {
        let lowercased = entry.lowercased()
        return lowercased == "meta.xml"
            || lowercased.hasPrefix("docprops/")
            || (lowercased.hasPrefix("metadata/")
                && (lowercased.hasSuffix(".xml") || lowercased.hasSuffix(".plist")))
    }

    private func scanMetadataText(_ text: String, path: String) {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if metadataIdentityRegex.firstMatch(in: text, range: range) != nil {
            add(rule: "document-identity-metadata", path: path)
        }
    }

    private func checkIdentity(result: Data, label: String) throws {
        let identity = String(decoding: result, as: UTF8.self)
        let regex = try NSRegularExpression(pattern: #"<([^>]+)>"#)
        let range = NSRange(identity.startIndex..<identity.endIndex, in: identity)

        guard let match = regex.firstMatch(in: identity, range: range),
              let emailRange = Range(match.range(at: 1), in: identity) else {
            add(rule: "commit-email-unreadable", path: "<\(label)>")
            return
        }

        if !isAllowedCommitEmail(String(identity[emailRange])) {
            add(rule: "personal-commit-email", path: "<\(label)>")
        }
    }

    private func add(rule: String, path: String) {
        findings.insert(Finding(rule: rule, path: path))
    }
}

private enum Mode {
    case selfTest
    case staged
    case worktree
    case revision(String)
    case prePush
}

private func runCommand(
    executable: String,
    arguments: [String],
    at directory: URL? = nil,
    input: Data? = nil,
    requireSuccess: Bool = true
) throws -> CommandResult {
    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()

    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    if let input {
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        try process.run()
        inputPipe.fileHandleForWriting.write(input)
        try inputPipe.fileHandleForWriting.close()
    } else {
        try process.run()
    }

    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
    _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    if requireSuccess, process.terminationStatus != 0 {
        throw NSError(
            domain: "PrivacyGuardCommand",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "Command failed: \(URL(fileURLWithPath: executable).lastPathComponent)"]
        )
    }

    return CommandResult(status: process.terminationStatus, output: output)
}

private func runGit(
    _ arguments: [String],
    at directory: URL,
    requireSuccess: Bool = true
) throws -> CommandResult {
    try runCommand(
        executable: "/usr/bin/git",
        arguments: arguments,
        at: directory,
        requireSuccess: requireSuccess
    )
}

private func repositoryRoot() throws -> URL {
    let currentDirectory = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    )
    let result = try runGit(["rev-parse", "--show-toplevel"], at: currentDirectory)
    let path = String(decoding: result.output, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return URL(fileURLWithPath: path, isDirectory: true)
}

private func nulSeparatedStrings(from data: Data) -> [String] {
    data.split(separator: 0)
        .compactMap { String(data: Data($0), encoding: .utf8) }
}

private func decodedText(from data: Data) -> String? {
    if let utf8 = String(data: data, encoding: .utf8) {
        return utf8
    }
    if let utf16 = String(data: data, encoding: .utf16) {
        return utf16
    }
    return nil
}

private func isAllowedRepositoryEmail(_ email: String) -> Bool {
    let lowercased = email.lowercased()
    return lowercased.hasSuffix("@example.com")
        || lowercased.hasSuffix("@example.org")
        || lowercased.hasSuffix("@example.net")
        || lowercased.hasSuffix(".invalid")
        || lowercased.hasSuffix("@users.noreply.github.com")
}

private func isAllowedCommitEmail(_ email: String) -> Bool {
    let lowercased = email.lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return lowercased.hasSuffix("@users.noreply.github.com")
        || lowercased.hasSuffix("@medmaskmac.invalid")
}

private func looksLikeChineseIdentityNumber(_ candidate: String) -> Bool {
    let characters = Array(candidate.uppercased())
    guard characters.count == 18 else {
        return false
    }

    let birthDate = String(characters[6...13])
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd"
    formatter.isLenient = false

    let hasPlausibleBirthDate: Bool
    if let date = formatter.date(from: birthDate) {
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        hasPlausibleBirthDate = (1900...Calendar.current.component(.year, from: Date())).contains(year)
    } else {
        hasPlausibleBirthDate = false
    }

    let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
    let checkCharacters = Array("10X98765432")
    var sum = 0

    for index in 0..<17 {
        guard let digit = characters[index].wholeNumberValue else {
            return hasPlausibleBirthDate
        }
        sum += digit * weights[index]
    }

    let hasValidChecksum = characters[17] == checkCharacters[sum % 11]
    return hasPlausibleBirthDate || hasValidChecksum
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
}

private func parseMode(arguments: [String]) throws -> Mode {
    guard let first = arguments.first else {
        throw NSError(
            domain: "PrivacyGuardUsage",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Expected --staged, --worktree, --ref, --pre-push, or --self-test"]
        )
    }

    switch first {
    case "--self-test":
        return .selfTest
    case "--staged":
        return .staged
    case "--worktree":
        return .worktree
    case "--ref":
        guard arguments.count == 2 else {
            throw NSError(
                domain: "PrivacyGuardUsage",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "--ref requires one revision"]
            )
        }
        return .revision(arguments[1])
    case "--pre-push":
        return .prePush
    default:
        throw NSError(
            domain: "PrivacyGuardUsage",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Unknown privacy guard mode"]
        )
    }
}

private func selfTest() -> Bool {
    let scanner = PrivacyScanner()
    let sensitiveID = "110105" + "19491231002" + "X"
    let personalEmail = "person" + "@" + "qq.com"
    let personalPath = "/Us" + "ers/alice/medical.pdf"
    let privatePath = "Private" + "Fixtures/OCR/sample.jpeg"
    let localDocumentPath = "Do" + "cs/local-notes.pdf"
    let loggingCall = "pr" + "int(recognizedText)"

    scanner.scanTextForSelfTest(sensitiveID, path: "sample.txt")
    scanner.scanTextForSelfTest(personalEmail, path: "sample.txt")
    scanner.scanTextForSelfTest(personalPath, path: "sample.txt")
    scanner.scanTextForSelfTest(privatePath, path: "sample.txt")
    scanner.scanTextForSelfTest(localDocumentPath, path: "sample.txt")
    scanner.scanTextForSelfTest(loggingCall, path: "OCRService.swift")
    scanner.scanMetadataForSelfTest("/Author (Example Person)", path: "sample.pdf")
    let cleanPNG = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!
    scanner.scanFileForSelfTest(cleanPNG, path: "sample.png")

    let rules = Set(scanner.findings.map(\.rule))
    let expected = Set([
        "chinese-identity-number",
        "personal-email",
        "personal-absolute-path",
        "forbidden-repository-path",
        "logging-in-ocr-source",
        "document-identity-metadata",
        "binary-review-required"
    ])

    let safeScanner = PrivacyScanner()
    safeScanner.scanTextForSelfTest(
        "test@example.com " + "Private" + "Fixtures/",
        path: "safe.txt"
    )

    let passed = expected.isSubset(of: rules)
        && !rules.contains("document-metadata-unreadable")
        && safeScanner.findings.isEmpty
    if !passed {
        writeError("Privacy guard self-test observed rules: \(rules.sorted().joined(separator: ", ")).\n")
    }
    return passed
}

private extension PrivacyScanner {
    func scanTextForSelfTest(_ text: String, path: String) {
        scanText(text, path: path)
    }

    func scanMetadataForSelfTest(_ text: String, path: String) {
        scanMetadataText(text, path: path)
    }

    func scanFileForSelfTest(_ data: Data, path: String) {
        scan(data: data, repositoryPath: path, displayPath: path)
    }
}

private func revisionsForPrePush(root: URL) throws -> [String] {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let text = String(decoding: input, as: UTF8.self)
    var revisions = [String]()
    var seen = Set<String>()

    for line in text.split(separator: "\n") {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 4 else {
            continue
        }

        let localObjectID = String(fields[1])
        let remoteObjectID = String(fields[3])
        guard localObjectID != zeroObjectID else {
            continue
        }

        let arguments: [String]
        if remoteObjectID == zeroObjectID {
            arguments = ["rev-list", "--reverse", localObjectID]
        } else {
            arguments = ["rev-list", "--reverse", "\(remoteObjectID)..\(localObjectID)"]
        }

        var result = try runGit(arguments, at: root, requireSuccess: false)
        if result.status != 0 {
            result = try runGit(
                ["rev-list", "--reverse", localObjectID],
                at: root
            )
        }

        for revision in String(decoding: result.output, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        where seen.insert(revision).inserted {
            revisions.append(revision)
        }
    }

    return revisions
}

private func report(_ scanner: PrivacyScanner) -> Bool {
    guard !scanner.findings.isEmpty else {
        writeOutput("Privacy guard passed: \(scanner.scannedFileCount) file snapshot(s) scanned.\n")
        return true
    }

    writeError("Privacy guard blocked the operation. Matched content is intentionally not printed.\n")
    for finding in scanner.findings.sorted(by: {
        ($0.path, $0.rule) < ($1.path, $1.rule)
    }) {
        writeError("[\(finding.rule)] \(finding.path)\n")
    }
    writeError("Remove the sensitive data or complete the documented binary review before retrying.\n")
    return false
}

private func writeOutput(_ message: String) {
    FileHandle.standardOutput.write(Data(message.utf8))
}

private func writeError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

private func main() throws -> Bool {
    let mode = try parseMode(arguments: Array(CommandLine.arguments.dropFirst()))

    if case .selfTest = mode {
        let passed = selfTest()
        writeOutput(passed ? "Privacy guard self-test passed.\n" : "Privacy guard self-test failed.\n")
        return passed
    }

    let root = try repositoryRoot()

    switch mode {
    case .selfTest:
        return true
    case .staged:
        let scanner = PrivacyScanner()
        try scanner.checkWorkingIdentity(at: root)
        try scanner.scan(source: RepositorySource(kind: .staged, root: root))
        return report(scanner)
    case .worktree:
        let scanner = PrivacyScanner()
        try scanner.checkWorkingIdentity(at: root)
        try scanner.scan(source: RepositorySource(kind: .worktree, root: root))
        return report(scanner)
    case let .revision(revision):
        let scanner = PrivacyScanner()
        try scanner.scan(source: RepositorySource(kind: .revision(revision), root: root))
        let objectType = try runGit(
            ["cat-file", "-t", revision],
            at: root,
            requireSuccess: false
        )
        if objectType.status == 0,
           String(decoding: objectType.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "commit" {
            try scanner.checkCommitIdentity(revision, at: root)
        }
        return report(scanner)
    case .prePush:
        let aggregate = PrivacyScanner()
        for revision in try revisionsForPrePush(root: root) {
            let scanner = PrivacyScanner()
            try scanner.scan(source: RepositorySource(kind: .revision(revision), root: root))
            try scanner.checkCommitIdentity(revision, at: root)
            aggregate.merge(scanner)
        }
        return report(aggregate)
    }
}

do {
    exit(try main() ? EXIT_SUCCESS : EXIT_FAILURE)
} catch {
    writeError("Privacy guard could not complete: \(error.localizedDescription)\n")
    exit(2)
}
