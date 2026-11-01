/// Product scope is independent of whether the user granted a system permission.
enum AppCapabilities {
    #if APP_STORE
    static let inAppDictation = true
    #else
    static let inAppDictation = false
    #endif
    static let requiresAccessibility = !inAppDictation
}
