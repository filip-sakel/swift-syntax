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
  // let originatingSyntax: TypeLikeSyntax

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
  /// Resolve the given type decl and look for the members in the given
  /// member chain (if not empty).
  /// E.g.
  /// ```swift
  /// struct A {
  ///   func f(_: A) {} // Look up `A` here
  /// }
  /// ```
  /// We'll generate two `lookInside(type:memberChain:)` requests.
  /// 1. One will be to resolve `struct A` selecting the member named
  ///    `.A` to see if `A` has any member types named `Self`.
  /// 2. The second request will be to resolve `struct A` with no selected member
  ///    (i.e. type `A` itself)
  case lookInsideType(TypeDeclSyntax, selectMember: UnqualifiedTypeLookupComponent?)

  /// Resolve the extension's extended type and look for the members in the given
  /// member chain (if not empty).
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
  case lookInsideExtension(ExtensionDeclSyntax, selectMember: UnqualifiedTypeLookupComponent?)
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
    case .lookForGenericParameters(let extensionDecl):
      return ".lookForGenericParameters(in: \(extensionDecl.trimmedDescription))"
    case .lookInImports(let imports):
      return ".lookInImports(\(imports.map(\.name)))"
    case .lookInModule:
      return "lookInModule"
    case .lookInsideExtension(let extensionDecl, let selectMember):
      return
        ".lookInsideExtension(\(extensionDecl.trimmedDescription), for: \(selectMember?.debugDescription ?? "nil"))"
    case .lookInsideType(let type, let selectMember):
      return ".lookInsideType(\(type.trimmedDescription), for: \(selectMember?.debugDescription ?? "nil")))"
    }
  }
}

// @_spi(_QualifiedLookup) public enum UnqualifiedResult {
//   case lookIn(PartiallyResolvedType, includeGenericParams: Bool)
// }

extension SyntaxProtocol {
  // func findUnqualifiedType1(identifier: Identifier?, name: Identifier?) -> TypeDeclSyntax? {
  //   // Get next parent
  //   var genericOrAssociated = [GenericParameterSyntax]()
  //   var parentNames = [TypeDeclSyntax]()
  //
  // }

  func findUnqualifiedType(
    _ typeName: Identifier,
    configuredRegions: ConfiguredRegions?
  ) -> [UnqualifiedTypeLookupResult] {
    let results: [LookupResult] = self.lookup(
      typeName,
      with: LookupConfig(configuredRegions: configuredRegions, _lookupTopScope: true)
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
            if let nominalDecl = declGroup.as(NominalTypeDeclSyntax2.self) {
              return UnqualifiedTypeLookupResult.lookInsideType(TypeDeclSyntax(nominalDecl), selectMember: nil)
            } else if let extensionDecl = declGroup.as(ExtensionDeclSyntax.self) {
              return UnqualifiedTypeLookupResult.lookInsideExtension(extensionDecl, selectMember: nil)
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

            return UnqualifiedTypeLookupResult.lookInsideType(typeDecl, selectMember: nil)
          // Identifiers, `self`, `newValue`, `error`, and `oldValue` can't be type decls.
          // Also, equivalent names always refers to identifiers in switch cases
          case .identifier, .implicit(.`self`), .implicit(.newValue), .implicit(.oldValue),
            .implicit(.error), .equivalentNames:
            return nil
          }
        })
      case .lookForMembers(let decl):
        // TODO: Should probably already be a `DeclGroupSyntaxType`
        guard let declGroup = DeclGroupSyntaxType(decl) else { return [] }
        let selectMember = UnqualifiedTypeLookupComponent(
          module: nil,
          name: typeName,
          originatingSyntax: .typeDecl(declGroup)
        )
        if let nominalDecl = declGroup.as(NominalTypeDeclSyntax2.self) {
          return [UnqualifiedTypeLookupResult.lookInsideType(TypeDeclSyntax(nominalDecl), selectMember: selectMember)]
        } else if let extensionDecl = declGroup.as(ExtensionDeclSyntax.self) {
          return [UnqualifiedTypeLookupResult.lookInsideExtension(extensionDecl, selectMember: selectMember)]
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
