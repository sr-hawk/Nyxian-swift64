//
//  NXBuildURL.swift
//  Nyxian
//
//  Build a project on request from another app on this phone, and say what happened.
//

import UIKit

/// `nyxian://build?project=<uuid>&type=run&x-success=<url>&x-error=<url>`
///
/// Why this exists: an agent app on the same phone can write Swift into a project here, but it had
/// no way to *compile* it — the human had to tap Run, which put a person in the middle of a loop
/// that is otherwise automatic. iOS gives no way for one app to invoke another's App Intent, and it
/// will not let a background app compile for minutes either, so the honest mechanism is the oldest
/// one: a URL brings Nyxian to the front, the build runs where the system allows it to run, and a
/// callback URL hands control back with the result.
///
/// Deliberately thin. It does not accept source, paths, flags or anything else that could change
/// what gets built — only *which* project, and run or export. Everything about the build is already
/// on disk, put there by whoever asked, through the Files layer they already have access to.
enum NXBuildURL {

    static let scheme = "nyxian"

    /// Handle a URL if it is ours. Returns false for anything else, so the caller can keep looking.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == scheme else { return false }
        guard url.host?.lowercased() == "build" else { return false }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        let success = value("x-success").flatMap(URL.init(string:))
        let failure = value("x-error").flatMap(URL.init(string:)) ?? success

        func reply(_ target: URL?, ok: Bool, reason: String) {
            guard let target,
                  var comps = URLComponents(url: target, resolvingAgainstBaseURL: false) else { return }
            var q = comps.queryItems ?? []
            q.append(URLQueryItem(name: "ok", value: ok ? "1" : "0"))
            q.append(URLQueryItem(name: "reason", value: reason))
            comps.queryItems = q
            guard let back = comps.url else { return }
            DispatchQueue.main.async { UIApplication.shared.open(back) }
        }

        guard let identifier = value("project"), !identifier.isEmpty else {
            reply(failure, ok: false, reason: "no project given")
            return true
        }

        // One build at a time. The builder is not re-entrant and a second caller would otherwise
        // corrupt the first one's cache rather than simply being told to wait.
        if NXBuilder.builds {
            reply(failure, ok: false, reason: "a build is already running")
            return true
        }

        let projectURL = NXBootstrap.shared().projectsURL.appendingPathComponent(identifier)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let project = NXProject(url: projectURL) else {
            reply(failure, ok: false, reason: "no project \(identifier)")
            return true
        }

        let buildType: NXBuilder.BuildType = (value("type")?.lowercased() == "export") ? .export : .run

        // Unsaved editors first: the caller wrote files underneath us through the Files layer, and
        // an open document holding an older copy in memory would overwrite them on the next save.
        NXDocumentManager.shared().saveAll {
            NXBuilder.builds = true
            NXBuilder.buildProject(withProject: project, buildType: buildType) { ok, _ in
                NXBuilder.builds = false
                // The diagnostics themselves are not sent back in the URL: they are already in
                // Documents/build.log, in full, and the caller can read far more there than a query
                // string should ever carry.
                reply(ok ? success : failure,
                      ok: ok,
                      reason: ok ? "built" : "build failed — see build.log")
            }
        }
        return true
    }
}
