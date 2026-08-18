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

// TODO: Remove Glibc import
@preconcurrency import Glibc
import SwiftIfConfig
import SwiftSyntax

// TODO: Add .lookForSupertype, .lookForDynamicMember & implemenet internal/external module lookup
@_spi(_QualifiedLookup) public final class SymbolTable {
  /// Invariant: moduleToSources[moduleName] != nil
  @_spi(_QualifiedLookupTests)
  public let moduleName: ModuleName
  @_spi(_QualifiedLookupTests)
  public let moduleToSources: [ModuleName: [String: SourceFileSyntax]]
  let configuredRegions: ConfiguredRegions?

  let _verbose: Bool = false
  let _logNestingLimit: Int? = nil
  var logPrefix = [String]()

  // Tracks requested extensions for extension binding
  var requestedExtensions: OrderedSet<Attached<ExtensionDeclSyntax>> = []

  /// TODO: Consider merging maps below
  //
  /// Useful map for finding the module of a file in constant time.
  private(set) lazy var moduleMap: [SourceFileSyntax: ModuleName] = _generateModuleMap()
  /// Useful map for finding file identifiers in constant time.
  /// E.g. `File.swift`, `Helpers/File.swift`
  private(set) lazy var fileMap: [SourceFileSyntax: String] = _generateFileMap()

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

extension SymbolTable {
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

  /// Initializes `fileMap`
  private func _generateFileMap() -> [SourceFileSyntax: String] {
    var result = [SourceFileSyntax: String]()
    for (_, sources) in moduleToSources {
      for (fileName, source) in sources {
        result[source] = fileName
      }
    }
    return result
  }
}

extension SymbolTable {
  /// Sorts results in increasing order by
  /// (a) Module name (alphabetically), (b) File id (alphabetically), and (c) File position (offset).
  ///
  /// Helps maintain deterministic outputs.
  func sortDeclarations(_ typeDecls: [Attached<TypeDeclSyntax>]) -> [Attached<TypeDeclSyntax>] {
    typeDecls.sorted(by: { a, b in
      // Compare modules
      let moduleA = moduleMap[a.fileRoot]!.name
      let moduleB = moduleMap[b.fileRoot]!.name
      guard moduleA == moduleB else {
        return moduleA < moduleB
      }

      // If modules are equal, compare file names
      let fileA = fileMap[a.fileRoot]!
      let fileB = fileMap[b.fileRoot]!
      guard fileA == fileB else {
        return fileA < fileB
      }

      // If file names are equal, compare positions
      return a.position < b.position
    })
  }
}

// MARK: Logging

extension SymbolTable {
  func log(_ component: Any, file: StaticString = #file, line: UInt = #line) {
    guard _verbose else { return }
    // Keep log text separately
    let newLine = "\(logPrefix.map({ "[\($0)]" }).joined()) \(component)\n"
    // logText += newLine + "\n"
    // Print new line
    print(newLine)
    // TODO: Remove
    fflush(stdout)
  }

  func withLogging<T>(
    request: String,
    describe: (T) -> String,
    perform action: (_ mutableSelf: borrowing SymbolTable) -> T,
    file: StaticString = #file,
    line: UInt = #line
  ) -> T {
    if let nestingLimit = self._logNestingLimit, logPrefix.count >= nestingLimit {
      fflush(stdout)
      fatalError(
        "Exceeded log nesting limit of \(nestingLimit), suggesting there's an infinite loop. If you think this is a mistake, you may change the limit in `TypeQualifier`."
      )
    }
    logPrefix.append(request)
    log("Resolving...", file: file, line: line)
    let result = action(self)
    log("Resolved \(describe(result))", file: file, line: line)
    logPrefix.removeLast()
    return result
  }
}

// MARK: DebugFileMap

extension SymbolTable {
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
