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

// TODO: Add .lookForSupertype, .lookForDynamicMember & implemenet internal/external module lookup
@_spi(_QualifiedLookup) public final class SymbolTable3 {
  /// Invariant: moduleToSources[moduleName] != nil
  @_spi(_QualifiedLookupTests)
  public let moduleName: ModuleName
  @_spi(_QualifiedLookupTests)
  public let moduleToSources: [ModuleName: [String: SourceFileSyntax]]
  let configuredRegions: ConfiguredRegions?

  /// Useful map for finding the module of a file in constant time.
  private(set) lazy var moduleMap: [SourceFileSyntax: ModuleName] = _generateModuleMap()

  /// `DebugFileMap` only has a runtime impact in DEBUG builds.
  internal lazy var debugFileMap: DebugFileMap = _generateDebugFileMap()

  // TODO: Setters should be private
  @_spi(_QualifiedLookupTests)
  public internal(set) lazy var unresolvedExtensions = _findUnresolvedExtensions()
  @_spi(_QualifiedLookupTests)
  public internal(set) var dependencyGraph = TypeDependencyGraph()

  public init?(
    moduleName: ModuleName,
    moduleToSources: [ModuleName: [String: SourceFileSyntax]],
    configuredRegions: ConfiguredRegions?
  ) {
    guard moduleToSources[moduleName] != nil else { return nil }

    self.moduleName = moduleName
    self.moduleToSources = moduleToSources
    self.configuredRegions = configuredRegions
  }
}

extension SymbolTable3 {
  /// Initializes `moduleMap`
  private func _generateModuleMap() -> [SourceFileSyntax: ModuleName] {
    var result = [SourceFileSyntax: ModuleName]()
    for (module, sources) in moduleToSources {
      for source in sources.values {
        result[source] = module
      }
    }
    return result
  }
}

// MARK: DebugFileMap

extension SymbolTable3 {
  private func _generateDebugFileMap() -> DebugFileMap {
    #if DEBUG
    // By `moduleName` invariant
    let internalSources = moduleToSources[moduleName]!

    // TODO: Check during init that each thing in the module map is a unique source file syntax
    // and add as invariant.
    let internalFileMap = Dictionary(
      uniqueKeysWithValues: internalSources.map({ (fileName, file) in
        (key: file.id, value: (fileName, file))
      })
    )
    return DebugFileMap(_internalFileMap: internalFileMap)
    #else
    return DebugFileMap()
    #endif
  }
}
