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

import SwiftSyntax

enum TypeNameResolution {
  case resolved(TypeName)
  case partial(PartialTypeName)
}
enum TypeNameResolutionFailure: Error {
  /// We need the fileRoot to be registered in the symbol table.
  case unregisteredFile
  /// We need all type names in the chain to be valid identifiers
  case invalidIdentifier(TokenSyntax)
}

struct PartialTypeName: CustomDebugStringConvertible {
  // Base and members should be in the same file
  let base: Attached<ExtensionDeclSyntax>
  /// The names of the members.
  ///
  /// E.g., in `extension Int { struct A { struct B {} } }` the
  /// members are "A" and "B"
  let memberNames: [Identifier]
  /// The main declaration of the partially resolved type or `nil` if the
  /// type is not yet resolved (``memberNames`` is empty).
  let mainDecl: Attached<NominalTypeDeclSyntax>?

  // IMPORTANT: Base and members must share the same fileSyntax root.
  init(
    base: Attached<ExtensionDeclSyntax>,
    members: [(mainDecl: Attached<NominalTypeDeclSyntax>, name: Identifier)]
  ) {
    // Map and check source file
    let memberNames = members.map({ (decl, name) in
      assert(
        decl.fileRoot == base.fileRoot,
        "[SwiftLexicalLookup] Internal error: Declaration's source file doesn't match base declaration's source file."
      )
      return name
    })

    self.base = base
    self.memberNames = memberNames
    self.mainDecl = members.last?.mainDecl
  }

  var debugDescription: String {
    let memberChain = memberNames.map(\.name).joined(separator: ".")
    return "<\(base.trimmedDescription)>.\(memberChain) (mainDecl: \(String(reflecting: mainDecl?.kind)))"
  }
}

extension Attached where Node == NominalTypeDeclSyntax {
  /// Walks to outer scopes to determine the type chain that uniquely identifies this type.
  ///
  /// Local types (e.g. `func f() { struct A { struct B {} } }`) always resolve.
  /// Global types can also fully resolve, but they only partially resolve if
  /// they're nested within an extension (e.g. `extension A { struct B {} }`).
  func resolveTypeName(symbolTable: SymbolTable) -> Result<TypeNameResolution, TypeNameResolutionFailure> {
    /// Parse the token into a valid identifier or throw
    func parseName(_ token: TokenSyntax) -> Result<Identifier, TypeNameResolutionFailure> {
      guard let identifier = Identifier(validating: token) else {
        return .failure(TypeNameResolutionFailure.invalidIdentifier(token))
      }
      return .success(identifier)
    }

    // Parse the first name
    let firstParsedName: Identifier
    switch parseName(node.name) {
    case .success(let success): firstParsedName = success
    case .failure(let failure): return .failure(failure)
    }

    var ancestor: Attached<Syntax>? = parent
    // All the members. Since we include `self`, `members.count>=1`
    var members = [(mainDecl: self, name: firstParsedName)]

    while let currentAncestor = ancestor {
      // Nominal types go to the front of the "chain"
      if let nominalTypeDecl: Attached<NominalTypeDeclSyntax> = currentAncestor.as(NominalTypeDeclSyntax.self) {
        let parsedName: Identifier
        switch parseName(nominalTypeDecl.node.name) {
        case .success(let success): parsedName = success
        case .failure(let failure): return .failure(failure)
        }
        members.insert((mainDecl: nominalTypeDecl, name: parsedName), at: 0)
      }
      // Extensions can't be resolved right now.
      else if let extensionDecl = currentAncestor.as(ExtensionDeclSyntax.self) {
        return .success(
          TypeNameResolution.partial(
            PartialTypeName(base: extensionDecl, members: members)
          )
        )
      }
      // Top-level scope
      else if currentAncestor.parent?.node == Syntax(self.fileRoot) {
        // Get the module from the symbol table
        guard let module = symbolTable.moduleMap[fileRoot] else {
          return .failure(TypeNameResolutionFailure.unregisteredFile)
        }
        // Create all the components
        let components = members.map({ (_, name) in
          GlobalTypeName.Component(
            name: name,
            file: fileRoot,
            module: module,
            symbolTable: symbolTable
          )
        })
        // Assert we have ennough members (we include `self` above)
        guard let globalType = GlobalTypeName(components: components) else {
          fatalError(
            "[SwiftLexicalLookup] Internal error: Unexpectedly got `nil` globalType, implying that `components` is empty, which shouldn't happen since `members` are always nonempty."
          )
        }

        return .success(
          TypeNameResolution.resolved(TypeName.global(globalType))
        )
      }
      // Nested scope (if CodeBlockItemListSyntax isn't nested directly under `SourceFileSyntax`)
      else if let scope = currentAncestor.as(CodeBlockItemListSyntax.self) {
        let components = members.map(\.name)

        // Assert we have enough members (we include `self` above)
        guard let localType = LocalTypeName(scope: scope, components: components) else {
          fatalError(
            "[SwiftLexicalLookup] Internal error: Unexpectedly got `nil` globalType, implying that `components` is empty, which shouldn't happen since `members` are always nonempty."
          )
        }

        return .success(
          TypeNameResolution.resolved(TypeName.local(localType))
        )
      }

      ancestor = currentAncestor.parent
    }

    // Shouldn't happen because we checked there's a source-file root above.
    fatalError(
      "[SwiftLexicalLookup] Internal error: Unexpectedly got no result despite having verified source-file root."
    )
  }
}
