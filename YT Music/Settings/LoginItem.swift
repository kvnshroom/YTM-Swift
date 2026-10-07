//
//  LoginItem.swift
//  YT Music
//

import OSLog
import ServiceManagement

/// The app's own login item (System Settings → General → Login Items).
enum LoginItem {
    private static let logger = Logger(subsystem: "moe.tenshii.YT-Music", category: "settings")

    static var isEnabled: Bool {
        [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    }

    static func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Login item update failed: \(error.localizedDescription)")
        }
    }
}
