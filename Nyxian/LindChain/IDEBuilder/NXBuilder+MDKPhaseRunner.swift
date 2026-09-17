/*
 SPDX-License-Identifier: AGPL-3.0-or-later

 Copyright (C) 2025 - 2026 emexlab

 This file is part of Nyxian.

 Nyxian is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Nyxian is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU Affero General Public License for more details.

 You should have received a copy of the GNU Affero General Public License
 along with Nyxian. If not, see <https://www.gnu.org/licenses/>.
*/

import MobileDevelopmentKit

extension NXBuilder: MDKPhaseRunnerDelegate {
    func runner(_ runner: MDKPhaseRunner,
                multithreadingThreadCountFor phase: MDKPhase) -> CFIndex {
        let userSelectedValue: NSNumber? = UserDefaults.standard.object(forKey: "cputhreads") as? NSNumber
        let userSelected = userSelectedValue?.intValue ?? CCGetMaximumPerformanceCores()
        return CFIndex(userSelected == 0 ? 1 : userSelected)
    }
    
    func runner(_ runner: MDKPhaseRunner,
                phase: MDKPhase,
                finishedRunning job: MDKJob,
                withResultingDiagnostics diagnostics: [MDKDiagnostic]?,
                withMainSource mainSource: String?,
                wasSuccessful success: Bool) {
        self.sawJobResult = true
        // Never let a failure be invisible: the unified log always gets the shape of the job, so a
        // build can be diagnosed over USB (idevicesyslog) even when nothing reaches the UI.
        if !success {
            NSLog("[NXBuilder] job FAILED type=\(job.type.rawValue) diagnostics=\(diagnostics?.count ?? -1) mainSource=\(mainSource ?? "nil") args=\(job.arguments.joined(separator: " "))")
            for d in diagnostics ?? [] {
                NSLog("[NXBuilder]   \(d.mainSource ?? "?"): \(d.message ?? "")")
            }
        }
        if let diagnostics = diagnostics,
           !diagnostics.isEmpty,
           mainSource == nil {
            // Diagnostics with no primary input (argument errors, module-load failures) used to be
            // dropped by the gate below. Record them under the job kind instead.
            self.database.addDiagnosticMessages(title: job.type == .linker ? "Linker" : "Compiler",
                                                items: diagnostics, clearPrevious: false)
        } else if let diagnostics = diagnostics,
           let mainSource = mainSource {
            self.database.removeFileDebug(ofPath: mainSource)
            if job.type == .linker {
                self.database.addDiagnosticMessages(title: "Linker", items: diagnostics, clearPrevious: true)
            } else {
                self.database.appendDebug(synItems: diagnostics)
            }
        } else if !success {
            // A job that dies without structured output used to vanish from the Issue Navigator
            // (measured 2026-09-14: the Swift frontend exits before any diagnostic when a module fails to
            // load). Record the failure with the job's arguments so it is never silent.
            let source = mainSource
                ?? job.arguments.last(where: { $0.hasSuffix(".swift") || $0.hasSuffix(".m") || $0.hasSuffix(".mm") || $0.hasSuffix(".c") || $0.hasSuffix(".cpp") })
                ?? self.project.url.path
            let kind = job.type == .linker ? "Linker" : "Compiler"
            guard let location = MDKFileSourceLocation(fileURL: URL(fileURLWithPath: source), with: CCSourceLocation()),
                  let item = MDKDiagnostic(type: .unknown, level: .error, mainSource: source, fileSourceLocation: location,
                                           message: "\(kind) job failed without producing diagnostics (the frontend exited early, e.g. a module could not be loaded). Arguments: \(job.arguments.joined(separator: " "))") else {
                return
            }
            self.database.addDiagnosticMessages(title: kind, items: [item], clearPrevious: false)
        }
    }
}

