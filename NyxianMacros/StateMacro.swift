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
// StateMacro.swift
//
// Nyxian's own reimplementation of SwiftUICore's `@State` macro
// (`#externalMacro(module: "SwiftUIMacros", type: "StateMacro")` in the
// iOS 27 SDK), loaded in-process by Nyxian's embedded Swift frontend via
// `-load-plugin-library`.
//
// This is a from-scratch reimplementation, not Apple's own StateMacro:
// Apple's plugin dylib (libSwiftUIMacros.dylib inside Xcode) is built
// against the *non*-underscored CompilerSwiftSyntax* module set and
// cannot be loaded by Nyxian's in-process frontend (which embeds the
// underscore-prefixed `_Compiler*` set instead -- module identity
// mismatch, measured 632/632 unresolved symbols). So this module must be
// named exactly `SwiftUIMacros` and expose a top-level, non-generic
// `StateMacro` type: the compiler resolves `#externalMacro(module:type:)`
// library plugins purely by mangled *name* lookup
// (swift-syntax's `LibraryPluginProvider._findAnyType`, which builds
// "<n><module><n><type>V/O/C" and calls `_typeByName` -- no protocol
// conformance search, no nesting support), so the module/type spelling
// here must match the SDK's declaration exactly.
//

import _CompilerSwiftDiagnostics
import _CompilerSwiftSyntax
import _CompilerSwiftSyntaxBuilder
import _CompilerSwiftSyntaxMacros

/// Reimplementation of `@State`'s accessor+peer expansion.
///
/// For `@State var x: T = e` this produces:
///
///     private var _x: State<T> = State(wrappedValue: e)
///     var $x: Binding<T> {
///       _x.projectedValue
///     }
///
/// as peers, and on `x` itself:
///
///     @storageRestrictions(initializes: _x)
///     init(initialValue) {
///       _x = State(wrappedValue: initialValue)
///     }
///     get { _x.wrappedValue }
///     set { _x.wrappedValue = newValue }
///
/// as accessors. `_x`/`$x` mirror `x`'s own access level. `@State var x: T?`
/// with no initializer expands as if `= nil` had been written. When `x` has
/// no type annotation, the storage type is inferred from a literal
/// initializer (Int/Double/String/Bool/array/dictionary); anything else is
/// a diagnostic, not a guess -- macros run on syntax, before full type
/// inference, so there is no way to ask the type checker what `e`'s type
/// will turn out to be.
public struct StateMacro: AccessorMacro, PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingAccessorsOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [AccessorDeclSyntax] {
    guard let binding = try singleStoredBinding(of: declaration, in: context) else {
      return []
    }
    guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
      context.diagnose(StateMacroDiagnostic.unsupportedPattern.diagnose(at: binding))
      return []
    }

    let storageName = "_\(name)"

    return [
      """
      @storageRestrictions(initializes: \(raw: storageName))
      init(initialValue) {
        \(raw: storageName) = State(wrappedValue: initialValue)
      }
      """,
      """
      get {
        \(raw: storageName).wrappedValue
      }
      """,
      """
      set {
        \(raw: storageName).wrappedValue = newValue
      }
      """,
    ]
  }

  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let varDecl = declaration.as(VariableDeclSyntax.self) else {
      context.diagnose(StateMacroDiagnostic.notAVariable.diagnose(at: declaration))
      return []
    }
    guard let binding = try singleStoredBinding(of: declaration, in: context) else {
      return []
    }
    guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
      context.diagnose(StateMacroDiagnostic.unsupportedPattern.diagnose(at: binding))
      return []
    }

    let storageName = "_\(name)"
    let projectedName = "$\(name)"

    // Access level: mirror whatever `x` itself declared (private,
    // fileprivate, internal, public, ...). No modifier at all means
    // "internal", which is also the safe default to re-emit as nothing.
    let accessModifiers = varDecl.modifiers.filter {
      switch $0.name.tokenKind {
      case .keyword(.private), .keyword(.fileprivate), .keyword(.internal),
        .keyword(.public), .keyword(.package):
        return true
      default:
        return false
      }
    }
    let accessPrefix =
      accessModifiers.isEmpty
      ? ""
      : accessModifiers.map { $0.trimmedDescription }.joined(separator: " ") + " "

    // Resolve the storage's element type: prefer the explicit annotation
    // on `x`; otherwise infer from a literal initializer. There is no
    // third option -- a macro cannot query the type checker for what an
    // arbitrary expression's inferred type will be.
    let typeName: String
    if let annotation = binding.typeAnnotation {
      typeName = annotation.type.trimmedDescription
    } else if let initializer = binding.initializer,
      let inferred = literalTypeName(of: initializer.value)
    {
      typeName = inferred
    } else {
      context.diagnose(StateMacroDiagnostic.needsTypeAnnotation.diagnose(at: binding))
      return []
    }

    // Initializer expression: `x`'s own initializer if present, else
    // (only reachable when there *was* a type annotation, e.g. `T?`) a
    // bare `nil`, matching `@State var x: T?` with no initializer.
    let initExprText = binding.initializer?.value.trimmedDescription ?? "nil"

    let storageDecl: DeclSyntax = """
      \(raw: accessPrefix)var \(raw: storageName): State<\(raw: typeName)> = State(wrappedValue: \(raw: initExprText))
      """
    let projectedDecl: DeclSyntax = """
      \(raw: accessPrefix)var \(raw: projectedName): Binding<\(raw: typeName)> {
        \(raw: storageName).projectedValue
      }
      """

    return [storageDecl, projectedDecl]
  }

  /// `@State` only ever attaches to a single `var name[: Type][ = expr]`
  /// binding. Anything else (multiple bindings on one line, a `let`, a
  /// tuple pattern) is a precise diagnostic rather than a crash or a
  /// silently-wrong expansion.
  private static func singleStoredBinding(
    of declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> PatternBindingSyntax? {
    guard let varDecl = declaration.as(VariableDeclSyntax.self) else {
      context.diagnose(StateMacroDiagnostic.notAVariable.diagnose(at: declaration))
      return nil
    }
    guard case .keyword(.var) = varDecl.bindingSpecifier.tokenKind else {
      context.diagnose(StateMacroDiagnostic.mustBeVar.diagnose(at: varDecl))
      return nil
    }
    guard varDecl.bindings.count == 1, let binding = varDecl.bindings.first else {
      context.diagnose(StateMacroDiagnostic.singleBindingOnly.diagnose(at: varDecl))
      return nil
    }
    guard binding.pattern.is(IdentifierPatternSyntax.self) else {
      context.diagnose(StateMacroDiagnostic.unsupportedPattern.diagnose(at: binding))
      return nil
    }
    return binding
  }

  /// Best-effort type name for a *literal* initializer expression. Macros
  /// operate on syntax, not the type-checked AST, so this only ever
  /// recognizes literal syntax shapes -- never arbitrary expressions.
  private static func literalTypeName(of expr: ExprSyntax) -> String? {
    if expr.is(IntegerLiteralExprSyntax.self) {
      return "Int"
    }
    if expr.is(FloatLiteralExprSyntax.self) {
      return "Double"
    }
    if expr.is(StringLiteralExprSyntax.self) {
      return "String"
    }
    if expr.is(BooleanLiteralExprSyntax.self) {
      return "Bool"
    }
    if let arrayExpr = expr.as(ArrayExprSyntax.self) {
      if arrayExpr.elements.isEmpty {
        return nil  // `[]` alone never carries an element type in its syntax.
      }
      var elementType: String?
      for element in arrayExpr.elements {
        guard let this = literalTypeName(of: element.expression) else {
          return nil
        }
        if let existing = elementType, existing != this {
          return nil  // mixed literal kinds -- give up, ask for an annotation.
        }
        elementType = this
      }
      guard let elementType else { return nil }
      return "[\(elementType)]"
    }
    if let dictExpr = expr.as(DictionaryExprSyntax.self) {
      guard case .elements(let elements) = dictExpr.content, !elements.isEmpty else {
        return nil  // `[:]` or an unrecognized content shape.
      }
      var keyType: String?
      var valueType: String?
      for element in elements {
        guard let thisKey = literalTypeName(of: element.key),
          let thisValue = literalTypeName(of: element.value)
        else {
          return nil
        }
        if let existingKey = keyType, existingKey != thisKey { return nil }
        if let existingValue = valueType, existingValue != thisValue { return nil }
        keyType = thisKey
        valueType = thisValue
      }
      guard let keyType, let valueType else { return nil }
      return "[\(keyType): \(valueType)]"
    }
    return nil
  }
}
