import Foundation

/// A database path that deliberately doesn't exist, so a fixture-driven test never
/// reads the real `~/.local/share/opencode/opencode.db` just because it didn't say
/// anything about opencode. Every read in `OpencodeStore` treats an unopenable file
/// as "no rows".
let NO_OPENCODE_DB = "/nonexistent/juancode-tests/opencode.db"
