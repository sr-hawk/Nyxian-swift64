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

//
// UnsupportedMacros.swift
//
// The iOS 27 SDK's SwiftUICore also declares these macro types in the
// SAME "SwiftUIMacros" module as StateMacro (per the module's own
// #externalMacro(module:type:) declarations for @State's helper macros
// and for @Entry/@Animatable). None of them are exercised by a plain
// `@State private var n = 0` -- StateMacro's OWN expansion (StateMacro.
// swift) never calls back into any of these, it writes the accessors/
// peers directly as syntax -- so leaving them unimplemented does not
// block @State.
//
// They are still registered here (each as a real, resolvable type in
// this module) rather than left out entirely: if user code ever writes
// `@Entry`/`@Animatable` and Nyxian's frontend tries to resolve
// "SwiftUIMacros.EntryMacro" etc. via -load-plugin-library, an ABSENT
// type fails with the compiler's own generic "external macro
// implementation type ... could not be found" message. Registering a
// real type that immediately diagnoses gives a precise, first-party
// error instead ("not implemented in Nyxian's SwiftUIMacros plugin
// yet") -- per the standing rule here: never silent, never a guess.
//
// NOT included: PreviewsMacros.SwiftUIView (#Preview). The SDK groups
// it under a *different* external-macro module name ("PreviewsMacros",
// not "SwiftUIMacros" -- confirmed by the dotted "PreviewsMacros.
// SwiftUIView" spelling used to name it), which would need its own
// separate plugin dylib (libPreviewsMacros.dylib) and its own
// -load-plugin-library entry. No measured fact here pins down that
// module's actual #externalMacro(module:type:) declaration (arity,
// attachment role, helper types), and guessing it wrong would either
// silently compile nothing useful or diagnose the wrong thing. Left
// as [RULING NEEDED] in the lane doc rather than implemented blind.
//

import _CompilerSwiftSyntax
import _CompilerSwiftSyntaxMacros

/// Shared body for every stub below: diagnose precisely, expand to
/// nothing. Kept as a free function (not a protocol default) so each
/// public macro type's own conformance to the real `PeerMacro` is
/// declared directly -- nothing about the sharing mechanism is part of
/// any type's public interface.
private func diagnoseUnimplemented(
  _ swiftUIMacroName: String,
  at node: AttributeSyntax,
  in context: some MacroExpansionContext
) -> [DeclSyntax] {
  context.diagnose(
    UnimplementedMacroDiagnostic(macroName: swiftUIMacroName).diagnose(at: node)
  )
  return []
}

// MARK: - @State's own helper macros (SDK: same "SwiftUIMacros" module)

public struct StatePropertyWrapperStorageMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    diagnoseUnimplemented("_StatePropertyWrapperStorage", at: node, in: context)
  }
}

public struct StateInitialStoredValueMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    diagnoseUnimplemented("_StateInitialStoredValue", at: node, in: context)
  }
}

public struct StateProjectedValueMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    diagnoseUnimplemented("_StateProjectedValue", at: node, in: context)
  }
}

public struct StateTypeMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    diagnoseUnimplemented("StateTypeMacro", at: node, in: context)
  }
}

// MARK: - @Entry / @Animatable

public struct EntryMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    diagnoseUnimplemented("Entry", at: node, in: context)
  }
}

public struct EntryDefaultValueMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    diagnoseUnimplemented("_EntryDefaultValue", at: node, in: context)
  }
}

public struct ProjectedValueMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    diagnoseUnimplemented("_ProjectedValue", at: node, in: context)
  }
}

public struct AnimatableMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    diagnoseUnimplemented("Animatable", at: node, in: context)
  }
}
