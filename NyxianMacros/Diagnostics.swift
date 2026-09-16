/*
 SPDX-License-Identifier: AGPL-3.0-or-later

 Copyright (C) 2026 emexlab

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

import _CompilerSwiftDiagnostics
import _CompilerSwiftSyntax

/// Diagnostics for `StateMacro`. Every failure path here is a precise
/// error, never a silent no-op or a guessed expansion.
enum StateMacroDiagnostic: String, DiagnosticMessage {
  case notAVariable
  case mustBeVar
  case singleBindingOnly
  case unsupportedPattern
  case needsTypeAnnotation

  var message: String {
    switch self {
    case .notAVariable:
      return "'@State' can only be attached to a variable declaration"
    case .mustBeVar:
      return "'@State' cannot be applied to a 'let' -- change it to 'var'"
    case .singleBindingOnly:
      return
        "'@State' does not support multiple bindings on one line (e.g. 'var a = 1, b = 2'); split them into separate declarations"
    case .unsupportedPattern:
      return "'@State' requires a simple 'var name' binding, not a tuple or other pattern"
    case .needsTypeAnnotation:
      return
        "'@State' could not infer this property's type from its initializer; add an explicit type annotation (e.g. 'var x: Int = ...')"
    }
  }

  var diagnosticID: MessageID {
    MessageID(domain: "org.emexlabs.nyxian.SwiftUIMacros", id: "StateMacro.\(rawValue)")
  }

  var severity: DiagnosticSeverity { .error }

  func diagnose(at node: some SyntaxProtocol) -> Diagnostic {
    Diagnostic(node: node, message: self)
  }
}

/// Shared diagnostic for every macro type this plugin exposes to satisfy
/// the SDK's external-macro declarations but does not yet implement.
/// Emitting this (rather than silently no-op'ing, or not registering the
/// type at all and letting the compiler print its own generic "external
/// macro implementation type ... could not be found" error) keeps the
/// failure precise: which macro, attached where.
struct UnimplementedMacroDiagnostic: DiagnosticMessage {
  let macroName: String

  var message: String {
    "'@\(macroName)' is not implemented in Nyxian's SwiftUIMacros plugin yet"
  }

  var diagnosticID: MessageID {
    MessageID(domain: "org.emexlabs.nyxian.SwiftUIMacros", id: "Unimplemented.\(macroName)")
  }

  var severity: DiagnosticSeverity { .error }

  func diagnose(at node: some SyntaxProtocol) -> Diagnostic {
    Diagnostic(node: node, message: self)
  }
}
