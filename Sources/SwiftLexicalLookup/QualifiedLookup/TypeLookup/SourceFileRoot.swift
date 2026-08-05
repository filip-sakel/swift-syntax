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

@_spi(_QualifiedLookupTests) public struct SourceFileRoot<Node: SyntaxProtocol> {
  /// Invariant: Must always be a node whose `root` is a `SourceFileSyntax`
  @_spi(_QualifiedLookupTests) public private(set) var node: Node

  private init(_unchecked: __shared Node) { self.node = _unchecked }
  private init?(_checked node: __shared some SyntaxProtocol) {
    // Root must be source file
    guard node._syntaxNode.root.is(SourceFileSyntax.self) else { return nil }

    guard let node = Node(node) else { return nil }
    self.init(_unchecked: node)
  }

  public var fileRoot: SourceFileSyntax {
    // By `_syntaxNode` invariant
    node.root.cast(SourceFileSyntax.self)
  }
}

// MARK: Casting

extension SourceFileRoot {
  @_spi(_QualifiedLookupTests) public init?(_ node: __shared Node) {
    self.init(_checked: node)
  }

  @_spi(_QualifiedLookupTests) public var parent: SourceFileRoot<Syntax>? {
    // Unchecked is fine since our parent must also be a child of the file root.
    node.parent.map({ SourceFileRoot<Syntax>(_unchecked: $0) })
  }

  @_spi(_QualifiedLookupTests) public func `as`<S: SyntaxProtocol>(_ syntaxType: S.Type) -> SourceFileRoot<S>? {
    // We force unwrap in case an implementation of `SyntaxProtocol/init` messed up.
    // However, casting should just change the type and not the root.
    node.as(syntaxType).map({ SourceFileRoot<S>($0)! })
  }

  @_spi(_QualifiedLookupTests) public func `is`<S: SyntaxProtocol>(_ syntaxType: S.Type) -> Bool {
    node.is(syntaxType)
  }
}

// MARK: Convenience

extension SourceFileRoot {
  internal var kind: SyntaxKind {
    node.kind
  }

  internal var trimmedDescription: String {
    node.trimmedDescription
  }

  internal var position: AbsolutePosition {
    node.position
  }
}

extension SourceFileRoot where Node == ExtensionDeclSyntax {
  internal var extendedType: SourceFileRoot<TypeSyntax> {
    // Extended type should be a child
    SourceFileRoot<TypeSyntax>(node.extendedType)!
  }
}
extension SourceFileRoot where Node == TypeAliasDeclSyntax {
  internal var initializerValue: SourceFileRoot<TypeSyntax> {
    // Initializer value should be a child
    SourceFileRoot<TypeSyntax>(node.initializer.value)!
  }
}

extension SourceFileRoot: Sendable where Node: Sendable {}
extension SourceFileRoot: Equatable where Node: Equatable {}
extension SourceFileRoot: Hashable where Node: Hashable {}

// MARK: Debug

@_spi(_QualifiedLookupTests)
extension SourceFileRoot: CustomDebugStringConvertible {
  public var debugDescription: String {
    node.trimmedDescription
  }
}
