//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SwiftIfConfig
import SwiftSyntax

@_spi(_QualifiedLookup) public struct UnqualifiedTypeLookupComponent: Sendable, CustomDebugStringConvertible {
  let module: Identifier?
  let name: Identifier

  public var debugDescription: String {
    let modulePrefix: String
    if let module {
      modulePrefix = "\(module.name)::"
    } else {
      modulePrefix = ""
    }
    return "\(modulePrefix)\(name.name)"
  }
}

// TODO: Every parent type needs to be resolved because even if we look for `A`
// in `extension String.UTF8View { struct A { func f(_: A) } }` and find `struct A`,
// we still need to bind extensions so we need to resolve `String.UTF8View`.
// I.e. Even if we find a matching type decl (and we know we can exit early),
//      qualifying the type means qualifying all parent scopes, which necessitates
//      resolving parent scopes.
enum UnqualifiedTypeLookupResult: CustomDebugStringConvertible {
  /// Resolve the given type decl and look for the desired member if
  /// ``lookForSelectedMember`` is `true`.
  ///
  /// E.g.
  /// ```swift
  /// struct A {
  ///   func f(_: A) {} // Look up `A` here
  /// }
  /// ```
  /// We'll generate two `lookInside(type:lookForSelectedMember:)` requests.
  /// 1. One will be to resolve `struct A` selecting the member named
  ///    `.A` to see if `A` has any member types named `Self`.
  /// 2. The second request will be to resolve `struct A` with no selected member
  ///    (i.e. type `A` itself)
  case lookForType(TypeDeclSyntax, lookForSelectedMember: Bool)

  /// Resolve the extension's extended type look for the desired member if
  /// ``lookForSelectedMember`` is `true`.
  ///
  /// E.g.
  /// ```swift
  /// extension A {
  ///   func f(_: Self) {} // Look up `Self` here
  /// }
  /// ```
  /// We'll generate two `lookInside(extension:memberChain:)` requests.
  /// 1. One will be to resolve `extension A` selecting the member named
  ///    `.Self` to see if `A` has any member types named `Self`.
  /// 2. The second request will be to resolve `extension A` with no selected member
  ///    (i.e. the extended type `A` itself)
  case lookForExtension(ExtensionDeclSyntax, lookForSelectedMember: Bool)
  /// E.g.
  /// ```swift
  /// extension Array {
  ///   func f(_: Element) {} // <- Element refers to a generic parameter
  /// }
  /// ```
  case lookForGenericParameters(extensionDecl: ExtensionDeclSyntax)
  case lookInModule
  case lookInImports([Identifier])

  var debugDescription: String {
    switch self {
    case .lookForExtension(let extensionDecl, let lookForSelectedMember):
      return
        ".lookForExtension(\(extensionDecl._memberlessDescription), lookForSelectedMember: \(lookForSelectedMember))"
    case .lookForType(let type, let lookForSelectedMember):
      return
        ".lookForType(\(type._memberlessDescription), lookForSelectedMember: \(lookForSelectedMember)))"
    case .lookForGenericParameters(let extensionDecl):
      return ".lookForGenericParameters(in: \(extensionDecl._memberlessDescription))"
    case .lookInModule:
      return ".lookInModule"
    case .lookInImports(let imports):
      return ".lookInImports(\(imports.map(\.name)))"
    }
  }

  /// Compact form of `debugDescription` for logging
  func _compactDescription(lookedUpName: Identifier) -> String {
    let memberSearchDescription = " > '\(lookedUpName.name)'"
    switch self {
    case .lookForExtension(let extensionDecl, let lookForSelectedMember):
      // E.g. 'extension A {}' > 'B'
      return
        "'\(extensionDecl._memberlessDescription)'\(lookForSelectedMember ? memberSearchDescription : ""))"
    case .lookForType(let type, let lookForSelectedMember):
      return
        "'\(type._memberlessDescription)'\(lookForSelectedMember ? memberSearchDescription : "")"
    case .lookForGenericParameters(let extensionDecl):
      return "'\(extensionDecl._memberlessDescription)' > generic parameters"
    case .lookInModule:
      return ".lookInModule"
    case .lookInImports(let imports):
      return ".lookInImports(\(imports.map(\.name)))"
    }
  }
}

extension SyntaxProtocol {
  func findUnqualifiedType(
    _ typeName: Identifier,
    configuredRegions: ConfiguredRegions?
  ) -> [UnqualifiedTypeLookupResult] {
    let results: [LookupResult] = self.lookup(
      typeName,
      with: LookupConfig(
        configuredRegions: configuredRegions,
        _lookupTopScope: true,
        _dontFindGenericParametersForExtendedType: true
      )
    )
    let filteredResults = results.flatMap({ result -> [UnqualifiedTypeLookupResult] in
      switch result {
      case .fromScope(_, let names):
        // Note that we skip non-type declarations, even if they have the same name.
        // For instance:
        //   struct A {
        //     func f() {
        //       let A = 1
        //       func A() {}
        //       var hey: A  = self
        //     }
        //   }
        return names.compactMap({ name -> UnqualifiedTypeLookupResult? in
          switch name {
          case .implicit(.`Self`(let decl)):
            // TODO: Should probably be DeclGroupSyntax to begin with
            guard let declGroup = decl.as(DeclGroupSyntaxType.self) else { return nil }
            if let nominalDecl = declGroup.as(NominalTypeDeclSyntax.self) {
              return UnqualifiedTypeLookupResult.lookForType(
                TypeDeclSyntax(nominalDecl),
                lookForSelectedMember: false
              )
            } else if let extensionDecl = declGroup.as(ExtensionDeclSyntax.self) {
              return UnqualifiedTypeLookupResult.lookForExtension(extensionDecl, lookForSelectedMember: false)
            } else {
              assertionFailure(
                "[SwiftLexicalLookup] Internal error: Expected declaration group to either be a nominal type or extension declaration."
              )
              return nil
            }
          case .declaration(let decl):
            // TODO: Should this be a ValueDeclSyntax?

            // Skip non-type declarations
            //
            // Note: We handle extensions above
            guard let typeDecl = TypeDeclSyntax(decl) else { return nil }

            return UnqualifiedTypeLookupResult.lookForType(typeDecl, lookForSelectedMember: false)
          case .identifier(let identifierSyntax, accessibleAfter: _):
            // The only `TypeDeclSyntax` "identifiers" are generic parameters.
            guard let genericParameter = identifierSyntax.as(GenericParameterSyntax.self) else { return nil }
            return UnqualifiedTypeLookupResult.lookForType(
              TypeDeclSyntax(genericParameter),
              lookForSelectedMember: false
            )
          // `self`, `newValue`, `error`, and `oldValue` can't be type decls.
          // Also, `equivalentNames` always refers to variable identifiers in
          // switch cases
          case .implicit(.`self`), .implicit(.newValue), .implicit(.oldValue),
            .implicit(.error), .equivalentNames:
            return nil
          }
        })
      case .lookForMembers(let decl):
        // TODO: Should probably already be a `DeclGroupSyntaxType`
        guard let declGroup = DeclGroupSyntaxType(decl) else { return [] }
        if let nominalDecl = declGroup.as(NominalTypeDeclSyntax.self) {
          return [UnqualifiedTypeLookupResult.lookForType(TypeDeclSyntax(nominalDecl), lookForSelectedMember: true)]
        } else if let extensionDecl = declGroup.as(ExtensionDeclSyntax.self) {
          return [UnqualifiedTypeLookupResult.lookForExtension(extensionDecl, lookForSelectedMember: true)]
        } else {
          assertionFailure(
            "[SwiftLexicalLookup] Internal error: Expected declaration group to either be a nominal type or extension declaration."
          )
          return []
        }
      case .lookForGenericParameters(let extensionDecl):
        return [.lookForGenericParameters(extensionDecl: extensionDecl)]
      // Closure parameters can't be type declarations
      case .lookForImplicitClosureParameters(_):
        return []
      }
    })
    // TODO: Expose imports
    return filteredResults + [.lookInModule, .lookInImports([])]
  }
}
