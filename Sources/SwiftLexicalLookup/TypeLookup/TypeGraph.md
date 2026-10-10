# `TypeGraph`

The `TypeGraph` is responsible for keeping track of types. Namely, it's a directed acyclic graph where types are nodes and extensions are edges. A graph is necessary because of two powerful Swift features:
1. Type aliases make finding extensions a global problem. To resolve “A,” we can’t just find `extension A {}`; we also need, say, `extension AliasedA {}`. Instead, we have to bind all accessible extensions to determine which extensions actually resolve to `A`.
2. We can extend a type declared in an extension, making extension binding incremental. In other words, one-by-one, we must resolve each extension, admit it into a dependency graph, and evict any dependent extensions.

### Example

```swift
struct A {}
//     `- Type 'MyModule::A'
extension A.B { struct A {} }
extension A { typealias B = A }
```

TODO: Refine graph/formal description
```
                    | MyModule > A |
                    /              \
                  /                  \
                /                      \
  `extension A { typealias B = A }`   <main-decl>
               |                          |
               |                          |
 | MyModule.A > B = [MyModule.A] |    | MyModule.A > A = [] |
                \                       /
                  \                   /
                    \               /
             `extension A.B { struct A {} }`
                           |
                           |
                     <cycle error>
```
Think about how you would determine what `extension A.B` refers to. You'll notice that you can't directly admit all extensions in order; instead, it's an incremental process that requires `TypeGraph`. The following section explains how exactly we admit extensions.

#### Process

At first, our graph sees only `struct A {}`. Starting from `extension A.B {}`, we admit the extension to the graph with a failed type, since `A` currently has no member `B`, and record that this extension depends on type `A`. The debug description now resembles this:

```swift
struct A {}
//     `- Type 'MyModule::A'
extension A.B { struct A {} }
//        |- Resolved type: failed (type 'A' has no member type 'B')
//        `- Depends on type 'A' > member 'B"
extension A { typealias B = A }
```

Moving on to the second extension, `extension A {}` resolves successfully to `A`, but `extension A.B {}` depends on `A`. To maintain the graph’s invariant, we first evict `extension A.B {}`, and then admit `extension A {}` into the graph.

```swift
struct A {}
//     `- Type 'MyModule::A'
extension A.B { struct A {} }
extension A { typealias B = A }
//        `- Resolved type: 'MyModule::A'
```

Finally, when we try to re-admit the evicted `extension A.B {}`, we run into a problem. If we bind `extension A.B {}` to “MyModule::A,” then the extension will depend on `struct A {}`, a type the extension itself introduces. Hence, we diagnose an extension-cycle error, which is more specific than the compiler’s current warning.

```swift
struct A {}
//     `- Type 'MyModule::A'
extension A.B { struct A {} }
//        |- Resolved type: failed (extension depends on itself)
//        `- Depends on type 'A' > member 'B"
extension A { typealias B = A }
//        `- Resolved type: 'MyModule::A'
```

## Implementation

Our graph is complex, so we need to maintain some core invariants:
1. Extensions point to valid types
   Each admitted extension that's bound to a type refers to a valid type.
1. Extensions depend on type members
   Extension dependencies (the set of type members used to resolve its type syntax) must match the type-member state in the graph. In practice, we admit an extension with valid dependencies, and evict it if the dependency type members change.
1. Dependencies and dependents match
   An extension can have a dependency on a type's member iff the type also records the extension as a dependent. Both the extension and type must be admitted.
1. Up-to-date dependencies
   Each extension dependency's type members must match
1. Nested types have parents
   If a type is nested under a nominal type declaration, that nominal type must be admitted. If a type is nested under an extension, that extension must be admitted. (Top-level types don't have that restriction.)
1. Extensions are top-level
   We cannot admit an extension nested under another extension or nominal-type declaration; it's illegal in Swift.

To maintain these invariants, we carefully gate all mutations through a set of core operations: adding and removing types and extensions.

### Core Operations

Only these operations should mutate the graph. Each core operation assumes the graph is valid, doesn't call other core operations in its body, and leaves the graph in a valid state.

### Add Type

`_addType` imposes the additional precondition that if the given type "Inner" is nested, it's parent "Outer" (resolved through a nominal type or extension) is admitted and without dependents on the member "Outer" > "Inner". `_addType` simply adds the given type node to the graph.

### Remove Type

`_removeType` imposes the additional precondition that the given type declaration have no bound extensions, or any type members, and it's parent doesn't have dependents on its member. `_removeType` simply removes the given type node from the graph.

### Add Extension

`_addExtension` imposes the additional precondition


Core Add/Remove Ops + Invariant Descriptions

### Lookup
Lookup Op

Document (either here or §Complexity) why it's slow

### Eviction Ops
Extension/Type Eviction + Example

## Complexity

## Design Rationale

#### Why not store type-member relations as edges?

Because type members don't have to be nominal-type declarations; they can be type aliases. But our nodes are just nominal types and their declarations.

### Why use `NominalTypeDeclSyntax` instead of `TypeSyntax`?

Because `TypeResolver` ultimately cares about resolving to unique nominal types. So, if we had `TypeSyntax` nodes, we'd essentially be caching the resolved type of type aliases. However, the graph is already complicated enough and caching at the graph level wouldn't necessarily improve performance.

