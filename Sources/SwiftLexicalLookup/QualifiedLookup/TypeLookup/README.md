# Overview

The symbol table facilitates lookup. The central API consists of looking up a declaration name reference in some type syntax. For instance, in type `Int` >lookup> `bitWidth`.

# Background

## Identifying Types

Before, we begin, it's useful to define a nominal type. For our purposes, a nominal type is any `struct`, `enum`, `class`, `actor` or *`protocol`*. An extended nominal type refers to the main declaration (`[Struct...]DeclSyntax`) and any extensions of that nominal type. We can identify nominal types by their main declaration. Further, it's good to have a robust naming system to unambiguously refer to nominal types. We define two different types of "qualified" type names:

### Top-level names
These are accessible from the top-level (without filtering for access control). They consist of one or more dot-separated components, each fully qualified.A fully qualified means we specify the module name. Additionally, for internal declarations (declared in our own module), we specify the file where the main declaration lives.

TODO: Does it make sense to extend these qualified identifiers to `DeclName`?

Specifying the file name for internal names disambiguates `fileprivate`
declarations. For instance:

```swift
```
// FileA.swift
fileprivate struct A {}
// FileB.swift
fileprivate struct A {}
```

```
```
```
Notes:
1. File IDs aren't necessary in external modules because we can assume everything comes in one module interface file where everything is public, or internal (e.g. for `@usableFromInline`).
2. File IDs are granular enough for internal declarations. That's because we can't declare types of the same name in the same type within the same file.

   Note: `private` is a little peculiar because it acts both as a lexical and semantic access-control modifier (see the [docs](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/accesscontrol/#Private-Members-in-Extensions). Namely, we can access private declarations across extensions/main declarations in the same file:
  ```swift
```
    struct A {
      private typealias T = Int
      struct B {
        // `T` is private to type `A`, but `B` can access it as
        // it's within the main declaration of `A` (lexical behavior)
        private func f(x: T) {}
      }
    }

    extension A {
      // `T` is accessible to extensions of `A` in the *same file*
      // (semantic because we extend `A`)
      private func g(x: T) {}
      typealias T = Int // ❌ Invalid redeclaration
    }

    extension A.B {
      // We meet neither the lexical (not nested in `A`) nor
      // semantic criteria (not an extension of `A`).
      private func g(x: T) {} // ❌ Cannot find `T` in scope
    }
  ```
```

  Examples include:
    a. `Swift::Int` (external module)
    b. `Swift::String.Foundation::Encoding` (different external modules)
    c. `Swift::Int.MyModule(FileA.swift)::A` and `Swift::Int.MyModule(FileB.swift)::A` in:
      ```swift
```
      // MyModule>FileA.swift
      extension Int {
        fileprivate struct A {}
      }
      // MyModule>FileB.swift
      extension Int {
        fileprivate struct A {}
      }
      ```
```
          ```
```
          ```

### Internal, nested-scope names
These are nested scopes, i.e., `CodeBlockItemListSyntax` that's not just
the top-level file scope.

Notes:
a. Types declared in nested scopes aren't accessible from the top-level.

  For instance, we can't access `A` in:
  ```swift
```
  ```swift
```
  ```
```
  ```swift
```
  func f() {
    struct A { // (f scope)->A
      struct B {} // (f scope)->A.B
    }
  }
  extension A {} // ❌ Cannot find `A`
  ```
```
  ```

```
  Hence, we only need to specify the scope for the base type of a
  member type syntax. That is, we don't write `(f scope)->A.(f scope)->B`.

b. Nested-scope types are only relevant for internal declarations.

  Since we can't access types declared in nested scopes from the top-level,
  they're only useful for type-checking and code generation. However,
  all external function/storage declarations have already been type checked.

  Hence, we don't need to specify the module; it's implicitly our module.

## Direct Lookup

Given a nominal type --meaning its main declaration and extensions-- we can look through each one to find the types direct members. We say directly because we don't look into supertypes (inherited protocols, superclasses, etc.).

We can, further, filter this lookup to directly look for type members.

# Process

Taking a step back, these are two operations: (1) find all declaration groups (nominal types
and extensions) that `Int` refers to, and (2) look up the declaration name reference `bitWidth`
in each.

## Resolving `TypeSyntax`

Type syntax need not refer directly to nominal types. In valid programs, any type syntax resolves to one or more extended nominal type or non-nominal base type. For instance, `Int` resolves to `Swift::Int`, and `Codable` (an alias for `Encodable & Decodable`) resolves to `Swift::Encodable` and `Swift::Decodable`.

Namely, type syntax broadly falls into the following categories (the compiler handles this in `directReferencesForTypeRepr`):
1. Nominal base case, `IdentifierTypeSyntax`.
   The rest of the article talks about resolving identifier type syntax. The compiler's `directReferencesForDeclRefTypeRepr` handles identifier type syntax along with member type syntax.
2. Non-nominal base cases:
   * `FunctionTypeSyntax` -> `callAsFunction` member, since function types are just callable
   * `TupleTypeSyntax` -> labels and indices as members, e.g. `(a: Int, Int)` has members `a`, `0` and `1`.
   * `MetatypeTypeSyntax`, `NamedOpaqueReturnTypeSyntax` -> no members
   * `MissingTypeSyntax`, `.Self` -> unresolvable (error)
3. Recursive cases:
   a. Perhaps the most common, `MemberTypeSyntax`, such as `(any MyProto).MyType`, resolves the base type and then issues a qualified lookup request on that resolved type, filtering for a `MyType` type declaration.

   b. Type sugar directly resolves to nominal types:
      * `ArrayTypeSyntax`, e.g., `[Int]` -> `Swift::Array`
      * `DictionaryTypeSyntax`, e.g., `[Int: String]` -> `Swift::Dictionary`
      * `InlineArrayTypeSyntax`, e.g., `[5 of Int]` -> `Swift::InlineArray`
      * `OptionalTypeSyntax`, such as `Int?`, `ImplicitlyUnwrappedOptionalTypeSyntax`, like `String?` -> `Swift::Optional`

   c. Non-nominal types which simply forward lookup to their base type:
      * `ClassRestrictionTypeSyntax`, e.g., `class MyClass`
      * `CompositionTypeSyntax`, e.g., `Encodable & Decodable` -> forward to *multiple* base types
      * `SomeOrAnyTypeSyntax`, e.g, `some Encodable`, `any Decodable`
      * `PackElementTypeSyntax`, e.g., `each Elements`
      * `PackExpansionTypeSyntax`, e.g., `repeat each Elements`
      * `TupleTypeSyntax`, e.g., `(a: Int,)` -> forwards only for single-element tuples (checked with `isParenType` in the compiler)
4. Special: `SuppressedTypeSyntax` (TODO: Handle)

To recap, recursively resolving type syntax, we end up with one or more bases cases; we handle each one separately:
1. For non-nominal, we directly resolve their members.
2. For unresolvable types, we report an error
3. For nominal, we talk about resolving the identifier syntax below.
Finally, we merge all results.

### Resolving `IdentifierTypeSyntax`

Extended nominal types consist of the main type declaration
(`[Struct/Enum/Class/Actor/Protocol]DeclSyntax`) and all the extensions
referencing them. Hence, to find the extended nominal type, we follow
the steps below:
1. Get the referenced base type declaration.
  Looking at the base of the member type syntax, there are two possibilities:
  1. There's a module selector => perform top-level, external-module lookup

      To see why we say top-level, consider the following example:
        extension String {
          func f(_: Swift::UTF8View) {} // ❌ `UTF8View` not imported through swift
          func g(_: UTF8View, _: Self..Swift::UTF8View) {} // ✅
        }
        let _: String.Swift::UTF8View // ✅
      Hence, despite `UTF8View` being a valid declaration within `String`,
      when we write `Swift::UTF8View`, we don't just filter normal qualified
      lookup to type declarations introduced in `Swift`, but we use a
      completely different process entirely.

    2. There's only an identifier => unqualified lookup

      Namely, we go up the syntax tree and look at potential names using
      `SyntaxProtocol/lookup(_:with:)`, including top-level results.
      We choose the first name that refers to a type declaration or extension:
      1. Look for names in scope
          a. Declaration -> try to cast to `DeclGroupSyntax`
          b. Implicit `Self` -> return associated `DeclGroupSyntax
          c. Else -> continue
            Identifier cannot represent type syntax. Equivalent names
            only occur in `switch` cases. Other implicit names (`self`,
            `newValue`, `oldValue`, `error`) can't be types.

      2. Look for members in declaration group
          Resolve declaration group to extended nominal type
          and perform qualified lookup.

      3. Generic parameters -> return (considered type declarations)

      4. Implicit closure parameters -> continue (can't be type syntax)

      If none of these yield any results, perform top-level lookup
      in our internal module, then top-level lookup in (implicitly)
      imported modules
      (TODO: Handle @_exported imports, specify shadowing order for
              imports)

      Now, we should have a type declaration or extension. If we have
      an extension, e.g. when searching for `Self` in `extension Int { func f(_: Self) }`,
      we need to resolve the extended type.

  We get the main declaration by performing unqualified lookup from the
  position of the type syntax looking for the base type name. For instance:
    struct A {
      func f() {
        struct A {
          func g(a: A) {}
                    `- Lookup `A` from here
        }
      }
    }
│     If unqualified lookup decides not to lie to us, we should get the nested
│     `struct A` declaration. This lookup is similar to the compiler's
│     `directReferencesForUnqualifiedTypeLookup`.

│  2. Resolve to a main nominal-type declaration.
│      Unqualified lookup simply returns a type declaration, which could be a:
│      a. Nominal type: great! we can move onto the next step
├───── b. Type alias: we need to recursively resolve the aliased type syntax
│      c. Associated type or generic parameter: we can't do much here (TODO:: Check the compiler also gives up)
│
│  3. Fully qualify the main type declaration.
│     We go up the syntax tree to find the first `CodeBlockItemListSyntax`
│     ancestor; this is our scope. There are two cases:
│     a. Our main declaration is a direct child of the scope node, so
│        we can qualify it:
│         i. If the scope's parent is a `SourceFileSyntax`, this is a
│            top-level name whose fully qualified name is:
│              MyModule(MyFile.swift)::MyType`.
│            E.g. In FileA.swift `struct A {}` becomes `MyModue(FileA.swift)::A`.
│        ii. Otherwise, we have a nested scope. The qualified name is:
│              (nested scope)->MyType
│            E.g. `func f() { struct A{} }` becomes `(f scope)->A`
│     b. Our main declaration has a declaration-group (nominal type declaration
│        or extension) parent, which we need to qualify first.
│         i. If the declaration-group parent is a nominal-type declaration,
│            we go to step (1).
╰─────── ii. If the declaration-group parent is an extension, recursively
          resolve the extended type syntax. Since we can only extend
          nominal types, the resolved type syntax should give us one
          extended nominal-type declaration. Based on the parent's type
          id, we construct this type's id:
          1. if the parent is a top-level id, we have:
              <parent id>.MyModule(MyFile.swift)::MyType
          2. if the parent is a nested scope, we have:
              <parent id>.MyType

After identifying the main declaration, we need to find its extensions.
For the lack of an easier way, we actually resolve all extended type
syntax (the compiler does this in `bindExtensions`).
  Note: This approach differs from our lazy computations up to this point: we've
        only been resolving type syntax that we know is relevant to our query.
        The reason is that to lazily find all extensions of a type, we need
        to know all of its aliases. Unfortunately, there's no easy way to find
        just one type's aliases without resolving *all* type aliases. Hence, it's
        easier to directly bind all extensions to a main nominal-type declaration.
Thus, the main declaration and every extension with the same type identifier forms
an _extended_ nominal type.

Finally, in this extended nominal type, we can perform qualified lookup
to find types (`directReferencesForQualifiedTypeLookup` in the compiler).
Namely, we call `_visitDirectMembers` on each `DeclGroupSyntax`
of the extended nominal type, and filter down to type declarations.
type declarations. We can then follow repeat the same process starting
from step (2). Thus, we've resolved a type identifier.

// TODO: Explain how this qualified lookup handles module selectors.

## Finding Members in Nominal Type
There are three cases depending on the type:
a. Nominal type: call `_visitDirectMembers` on the main declaration
  and extensions' 'DeclGroupSyntax'
