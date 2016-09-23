#if os(Linux)
    import Glibc
#else
    import Darwin.C
#endif

@_exported import Core
import CLibvenice

public enum FileMode {
    case read
    case createWrite
    case truncateWrite
    case appendWrite
    case readWrite
    case createReadWrite
    case truncateReadWrite
    case appendReadWrite
}

extension FileMode {
    var value: Int32 {
        switch self {
        case .read: return O_RDONLY
        case .createWrite: return (O_WRONLY | O_CREAT | O_EXCL)
        case .truncateWrite: return (O_WRONLY | O_CREAT | O_TRUNC)
        case .appendWrite: return (O_WRONLY | O_CREAT | O_APPEND)
        case .readWrite: return (O_RDWR)
        case .createReadWrite: return (O_RDWR | O_CREAT | O_EXCL)
        case .truncateReadWrite: return (O_RDWR | O_CREAT | O_TRUNC)
        case .appendReadWrite: return (O_RDWR | O_CREAT | O_APPEND)
        }
    }
}

public final class File : Stream {
    fileprivate var file: mfile?
    public fileprivate(set) var closed = false
    public fileprivate(set) var path: String? = nil

    public func cursorPosition() throws -> Int {
        let position = Int(filetell(file))
        try ensureLastOperationSucceeded()
        return position
    }

    public func seek(cursorPosition: Int) throws -> Int {
        let position = Int(fileseek(file, off_t(cursorPosition)))
        try ensureLastOperationSucceeded()
        return position
    }

    public var length: Int {
        return Int(filesize(self.file))
    }

    public var cursorIsAtEndOfFile: Bool {
        return fileeof(file) != 0
    }

    public lazy var fileExtension: String? = {
        guard let path = self.path else {
            return nil
        }

        guard let fileExtension = path.split(separator: ".").last else {
            return nil
        }

        if fileExtension.split(separator: "/").count > 1 {
            return nil
        }

        return fileExtension
    }()

    init(file: mfile) {
        self.file = file
    }

    public convenience init(fileDescriptor: FileDescriptor) throws {
        let file = fileattach(fileDescriptor)
        try ensureLastOperationSucceeded()
        self.init(file: file!)
    }

    public convenience init(path: String, mode: FileMode = .read) throws {
        let file = fileopen(path, mode.value, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        try ensureLastOperationSucceeded()
        self.init(file: file!)
        self.path = path
    }

    deinit {
        if let file = file, !closed {
            fileclose(file)
        }
    }
}

extension File {
    
    public func write(_ buffer: UnsafeBufferPointer<UInt8>, deadline: Double = .never) throws {
        guard !buffer.isEmpty else {
            return
        }
        
        try ensureFileIsOpen()
        
        let bytesWritten = filewrite(file, buffer.baseAddress!, buffer.count, deadline.int64milliseconds)
        guard bytesWritten == buffer.count else {
            try ensureLastOperationSucceeded()
            throw SystemError.other(errorNumber: -1)
        }
    }

    public func read(into: UnsafeMutableBufferPointer<UInt8>, deadline: Double = .never) throws -> Int {
        guard !into.isEmpty else {
            return 0
        }
        
        try ensureFileIsOpen()
        
        let bytesRead = filereadlh(file, into.baseAddress!, 1, into.count, deadline.int64milliseconds)
        
        if bytesRead == 0 {
            try ensureLastOperationSucceeded()
        }
        
        return bytesRead
    }

    public func readAll(bufferSize: Int = 2048, deadline: Double = .never) throws -> Buffer {
        var buffer = Buffer.empty
        
        while true {
            let chunk = try self.read(upTo: bufferSize, deadline: deadline)
            
            if chunk.count == 0 || cursorIsAtEndOfFile {
                break
            }
            
            buffer.append(chunk)
        }
        
        return buffer
    }

    public func flush(deadline: Double) throws {
        try ensureFileIsOpen()
        fileflush(file, deadline.int64milliseconds)
        try ensureLastOperationSucceeded()
    }

    public func close() {
        if !closed {
            fileclose(file)
        }
        closed = true
    }

    private func ensureFileIsOpen() throws {
        if closed {
            throw StreamError.closedStream(buffer: Buffer())
        }
    }
}

extension File {
    public static var workingDirectory: String {
        var buffer = [Int8](repeating: 0, count: Int(MAXNAMLEN))
        let workingDirectory = getcwd(&buffer, buffer.count)
        return String(cString: workingDirectory!)
    }

    public static func changeWorkingDirectory(path: String) throws {
        if chdir(path) == -1 {
            try ensureLastOperationSucceeded()
        }
    }

    public static func contentsOfDirectory(path: String) throws -> [String] {
        var contents: [String] = []

        guard let dir = opendir(path) else {
            try ensureLastOperationSucceeded()
            return []
        }

        defer {
            closedir(dir)
        }

        let excludeNames = [".", ".."]

        while let file = readdir(dir) {
            let entry: UnsafeMutablePointer<dirent> = file

            if let entryName = withUnsafeMutablePointer(to: &entry.pointee.d_name, { (ptr) -> String? in
                let entryPointer = unsafeBitCast(ptr, to: UnsafePointer<CChar>.self)
                return String(validatingUTF8: entryPointer)
            }) {
                if !excludeNames.contains(entryName) {
                    contents.append(entryName)
                }
            }
        }

        return contents
    }

    public static func fileExists(path: String) -> Bool {
        var s = stat()
        return lstat(path, &s) >= 0
    }

    public static func isDirectory(path: String) -> Bool {
        var s = stat()
        if lstat(path, &s) >= 0 {
            if (s.st_mode & S_IFMT) == S_IFLNK {
                if stat(path, &s) >= 0 {
                    return (s.st_mode & S_IFMT) == S_IFDIR
                }
                return false
            }
            return (s.st_mode & S_IFMT) == S_IFDIR
        }
        return false
    }

    public static func createDirectory(path: String, withIntermediateDirectories createIntermediates: Bool = false) throws {
        if createIntermediates {
            let (exists, directory) = (fileExists(path: path), isDirectory(path: path))
            if !exists {
                let parent = path.dropLastPathComponent()

                if !fileExists(path: parent) {
                    try createDirectory(path: parent, withIntermediateDirectories: true)
                }
                if mkdir(path, S_IRWXU | S_IRWXG | S_IRWXO) == -1 {
                    try ensureLastOperationSucceeded()
                }
            } else if directory {
                return
            } else {
                throw SystemError.fileExists
            }
        } else {
            if mkdir(path, S_IRWXU | S_IRWXG | S_IRWXO) == -1 {
                try ensureLastOperationSucceeded()
            }
        }
    }

    public static func removeFile(path: String) throws {
        if unlink(path) != 0 {
            try ensureLastOperationSucceeded()
        }
    }

    public static func removeDirectory(path: String) throws {
        if fileremove(path) != 0 {
            try ensureLastOperationSucceeded()
        }
    }
}

// Warning: We're gonna need this when we split Venice from Quark in the future

// extension String {
//     func split(separator: Character, maxSplits: Int = .max, omittingEmptySubsequences: Bool = true) -> [String] {
//         return characters.split(separator: separator, maxSplits: maxSplits, omittingEmptySubsequences: omittingEmptySubsequences).map(String.init)
//     }
//
//    public func has(prefix: String) -> Bool {
//        return prefix == String(self.characters.prefix(prefix.characters.count))
//    }
//
//    public func has(suffix: String) -> Bool {
//        return suffix == String(self.characters.suffix(suffix.characters.count))
//    }
//}

extension String {
    func dropLastPathComponent() -> String {
        let string = self.fixSlashes()

        if string == "/" {
            return string
        }

        switch string.startOfLastPathComponent {

        // relative path, single component
        case string.startIndex:
            return ""

        // absolute path, single component
        case string.index(after: startIndex):
            return "/"

        // all common cases
        case let startOfLast:
            return String(string.characters.prefix(upTo: string.index(before: startOfLast)))
        }
    }

    func fixSlashes(compress: Bool = true, stripTrailing: Bool = true) -> String {
        if self == "/" {
            return self
        }

        var result = self

        if compress {
            result.withMutableCharacters { characterView in
                let startPosition = characterView.startIndex
                var endPosition = characterView.endIndex
                var currentPosition = startPosition

                while currentPosition < endPosition {
                    if characterView[currentPosition] == "/" {
                        var afterLastSlashPosition = currentPosition
                        while afterLastSlashPosition < endPosition && characterView[afterLastSlashPosition] == "/" {
                            afterLastSlashPosition = characterView.index(after: afterLastSlashPosition)
                        }
                        if afterLastSlashPosition != characterView.index(after: currentPosition) {
                            characterView.replaceSubrange(currentPosition ..< afterLastSlashPosition, with: ["/"])
                            endPosition = characterView.endIndex
                        }
                        currentPosition = afterLastSlashPosition
                    } else {
                        currentPosition = characterView.index(after: currentPosition)
                    }
                }
            }
        }

        if stripTrailing && result.has(suffix: "/") {
            result.remove(at: result.characters.index(before: result.characters.endIndex))
        }

        return result
    }

    var startOfLastPathComponent: String.CharacterView.Index {
        precondition(!has(suffix: "/") && characters.count > 1)

        let characterView = characters
        let startPos = characterView.startIndex
        let endPosition = characterView.endIndex
        var currentPosition = endPosition

        while currentPosition > startPos {
            let previousPosition = characterView.index(before: currentPosition)
            if characterView[previousPosition] == "/" {
                break
            }
            currentPosition = previousPosition
        }

        return currentPosition
    }
}
