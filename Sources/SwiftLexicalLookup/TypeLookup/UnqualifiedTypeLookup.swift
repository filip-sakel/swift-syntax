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
  /// Resolve the given type decl, collecting redeclarations and
  /// the parent 'with-statements' scope containing these declarations.
  // TODO: Should I remove `redeclarations`?
  case nonNestedTypeDecl(
    decl: Attached<TypeDeclSyntax>,
    redeclarations: [Attached<TypeDeclSyntax>],
    parentScope: Attached<CodeBlockItemListSyntax>
  )

  /// Search for the given type declaration as a member of `declGroupParent`.
  /// If `lookForSelf==true`, then we're not looking for the identifier `Self`,
  /// but for implicit `Self` instead.
  case lookForMember(declGroupParent: Attached<DeclGroupSyntaxType>, lookForSelf: Bool)

  /// E.g.
  /// ```swift
  /// extension Array {
  ///   func f(_: Element) {} // <- Element refers to a generic parameter
  /// }
  /// ```
  case lookForGenericParameters(extensionDecl: Attached<ExtensionDeclSyntax>)
  case lookInModule
  case lookInImports([Identifier])

  var debugDescription: String {
    switch self {
    case .lookForExtension(let extensionDecl, let lookForSelectedMember):
      return
        ".lookForExtension(\(extensionDecl._memberlessDescription), lookForSelectedMember: \(lookForSelectedMember))"
    case .lookForType(let type, let lookForSelectedMember, let scope):
      return
        ".lookForType(decls: [\(type.map(\._memberlessDescription).joined(separator: ", "))], lookForSelectedMember: \(lookForSelectedMember)))"
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
        "[\(type.map(\._memberlessDescription).joined(separator: ", "))]\(lookForSelectedMember ? memberSearchDescription : "")"
    case .lookForGenericParameters(let extensionDecl):
      return "'\(extensionDecl._memberlessDescription)' > generic parameters"
    case .lookInModule:
      return ".lookInModule"
    case .lookInImports(let imports):
      return ".lookInImports(\(imports.map(\.name)))"
    }
  }
}

extension Attached {
  func findUnqualifiedType(
    _ typeName: Identifier,
    configuredRegions: ConfiguredRegions?
  ) -> [UnqualifiedTypeLookupResult] {
    let results: [LookupResult] = node.lookup(
      typeName,
      with: LookupConfig(
        configuredRegions: configuredRegions,
        _lookupTopScope: true,
        _dontFindGenericParametersForExtendedType: true
      )
    )

    // We force unwrap because unqualified lookup just visits outer
    // scopes in the file, so we should still have a file root
    func castChild<S: SyntaxProtocol>(_ syntax: S) -> Attached<S> {
      Attached<S>(syntax)!
    }

    let filteredResults = results.compactMap({ result -> UnqualifiedTypeLookupResult? in
      switch result {
      case .fromScope(let scope, let names):
        // Note that we skip non-type declarations, even if they have the same name.
        // For instance:
        //   struct A {
        //     func f() {
        //       let A = 1
        //       func A() {}
        //       var hey: A  = self
        //     }
        //   }
        var typeDecls = [Attached<TypeDeclSyntax>]()
        for name: LookupName in names {
          switch name {
          case .implicit(.`Self`(let decl)):
            // According to the docs, `decl` is either a protocol or extension decl.
            //
            // TODO: Should probably be DeclGroupSyntax to begin with
            //
            // TODO: How do we handle top-level `Self` or `Self` in a method, e.g.:
            // // File.swift
            // func f() { let _: Self } // What error?
            // struct A {
            //   func g() { let _: Self } // Refers to `A`
            // }
            guard let declGroup = decl.as(DeclGroupSyntaxType.self) else {
              fatalError(
                "[SwiftLexicalLookup] Internal error: Expected syntax in .implicit(.Self) to be a declaration group but got \(decl.kind) instead."
              )
            }
            // Only return implicit `Self` if we don't have other matching
            // declarations (also named `Self`).
            guard typeDecls.isEmpty else { continue }

            return UnqualifiedTypeLookupResult.lookForMember(
              declGroupParent: castChild(declGroup),
              lookForSelf: true
            )
          case .declaration(let decl):
            // TODO: Should this be a ValueDeclSyntax?

            // Skip non-type declarations
            //
            // Note: We handle extensions above
            guard let typeDecl = TypeDeclSyntax(decl) else { continue }

            typeDecls.append(castChild(typeDecl))
          case .identifier(let identifierSyntax, accessibleAfter: _):
            // The only `TypeDeclSyntax` "identifiers" are generic parameters.
            guard let genericParameter = identifierSyntax.as(GenericParameterSyntax.self) else { continue }
            typeDecls.append(castChild((TypeDeclSyntax(genericParameter))))

          // `self`, `newValue`, `error`, and `oldValue` can't be type decls.
          // Also, `equivalentNames` always refers to variable identifiers in
          // switch cases
          case .implicit(.`self`), .implicit(.newValue), .implicit(.oldValue),
            .implicit(.error), .equivalentNames:
            return nil
          }
        }

        // Skip if we couldn't find type declarations
        guard let firstTypeDecl = typeDecls.first else { return nil }
        let redeclarations = Array(typeDecls[1...])

        // Return based on scope: either nested (under a decl group) or
        // non-nested (directly under a CodeBlockItemListSyntax, like a
        // source file or function body)
        //
        // Note: Type decls in a `.fromScope` result should be introduced
        // by a `WithStatementsSyntax` scope. The only non-`WithStatementsSyntax`
        // scopes are:
        // 1. implicit `Self` inside an `AccessorDeclSyntax` or an `ExtensionDeclSyntax`,
        // 2. `guard` statements (which can't introduce types), and
        // 3. associated types inside protocol declarations
        //
        // Rationale: We surface regular type decls introduced in a declaration
        // group with `.lookForMembers`, since qualified lookup needs to handle
        // those, e.g.:
        // ```swift
        // struct A {
        //   struct B {
        //     func f(_: B) {} // <- Look up here
        //   }
        // }
        // ```
        // We defer to qualified lookup because if we later had
        // `extension A { typealias B = () }`, we'd need to diagnose the
        // ambiguity.
        if let statementScope = scope.asProtocol((any WithStatementsSyntax).self) {
          return UnqualifiedTypeLookupResult.nonNestedTypeDecl(
            decl: firstTypeDecl,
            redeclarations: redeclarations,
            parentScope: castChild(statementScope.statements)
          )
        } else if let protocolParent = scope.as(ProtocolDeclSyntax.self) {
          // As described above, this happens only for associated types.
          // We'll find all types, not just the associated types.
          // TODO: Check what the compiler does; might need to change behaviors
          //
          // Note `typealias`es of associated types in protocol extensions are peculiar;
          // they don't participate in lookup; the just act like default values
          //   (TODO: find precise rules).
          // ```swift
          // protocol P {
          //     associatedtype T
          // }
          // extension P {
          //     typealias T = Int
          //     func f(x: T) {
          //         let int: Int = x
          //         // ❌ error: cannot convert value of type 'Self.T' to specified type 'Int'
          //     }
          // }
          // struct A: P { typealias T = () }
          // // ✅ No redeclaration error
          //
          // struct B: P {}
          // // ✅ `T` inferred as `Int`
          //
          // let _: (any P).T = 0
          // let _: P.T = 0
          // // ❌ error: cannot access associated type 'T' from 'any P'
          // ```
          return UnqualifiedTypeLookupResult.lookForMember(
            declGroupParent: castChild(DeclGroupSyntaxType(protocolParent)),
            lookForSelf: false
          )
        } else {
          // Shouldn't happen; TODO: Make sure
          fatalError(
            "[SwiftLexicalLookup] Internal error: Expected a `WithStatementsSyntax` or `protocol` scope but got `\(scope.kind)` for names: \(names)"
          )
        }
      case .lookForMembers(let parentSyntax):
        // TODO: Should probably already be a `DeclGroupSyntaxType`
        guard let declGroupParent = DeclGroupSyntaxType(parentSyntax) else {
          fatalError(
            "[SwiftLexicalLookup] Internal error; Expected .lookForMembers to have a DeclGroupSyntax but found \(parentSyntax.kind)."
          )
        }
        // TODO: Should still return redecls of `decl` if they exist?? (or will symbol table handle that?)
        return UnqualifiedTypeLookupResult.lookForMember(
          declGroupParent: castChild(declGroupParent),
          lookForSelf: false
        )
      case .lookForGenericParameters(let extensionDecl):
        return UnqualifiedTypeLookupResult.lookForGenericParameters(extensionDecl: castChild(extensionDecl))
      // Closure parameters can't be type declarations
      case .lookForImplicitClosureParameters(_):
        return nil
      }
    })
    // TODO: Expose imports
    return filteredResults + [.lookInModule, .lookInImports([])]
  }
}
