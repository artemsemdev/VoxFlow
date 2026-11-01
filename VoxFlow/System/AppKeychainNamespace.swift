/// The sandboxed product must never reuse the desktop edition's history key or MCP token.
/// Keep the desktop namespace stable so updating it does not orphan existing encrypted history.
enum AppKeychainNamespace {
    #if APP_STORE
    static let service = "dev.artemsem.voxflow.store"
    #else
    static let service = "dev.artemsem.voxflow"
    #endif
}
