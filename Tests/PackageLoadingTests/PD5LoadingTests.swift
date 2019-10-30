/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest

import TSCBasic
import TSCUtility
import SPMTestSupport
import PackageModel
import PackageLoading

// FIXME: We should share the infra with other loading tests.
class PackageDescription5LoadingTests: XCTestCase {
    let manifestLoader = ManifestLoader(manifestResources: Resources.default)

    private func loadManifestThrowing(
        _ contents: ByteString,
        line: UInt = #line,
        body: (Manifest) -> Void
    ) throws {
        let fs = InMemoryFileSystem()
        let manifestPath = AbsolutePath.root.appending(component: Manifest.filename)
        try fs.writeFileContents(manifestPath, bytes: contents)
        let m = try manifestLoader.load(
            package: AbsolutePath.root,
            baseURL: "/foo",
            manifestVersion: .v5,
            fileSystem: fs)
        guard m.manifestVersion == .v5 else {
            return XCTFail("Invalid manfiest version")
        }
        body(m)
    }

    private func loadManifest(
        _ contents: ByteString,
        line: UInt = #line,
        body: (Manifest) -> Void
    ) {
        do {
            try loadManifestThrowing(contents, line: line, body: body)
        } catch ManifestParseError.invalidManifestFormat(let error, _) {
            print(error)
            XCTFail(file: #file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: #file, line: line)
        }
    }

    func testBasics() {
        let stream = BufferedOutputByteStream()
        stream <<< """
            import PackageDescription
            let package = Package(
                name: "Trivial",
                products: [
                    .executable(name: "tool", targets: ["tool"]),
                    .library(name: "Foo", targets: ["Foo"]),
                ],
                dependencies: [
                    .package(url: "/foo1", from: "1.0.0"),
                ],
                targets: [
                    .target(
                        name: "foo",
                        dependencies: ["dep1", .product(name: "product"), .target(name: "target")]),
                    .testTarget(
                        name: "bar",
                        dependencies: ["foo"]),
                ]
            )
            """

        loadManifest(stream.bytes) { manifest in
            XCTAssertEqual(manifest.name, "Trivial")

            // Check targets.
            let targets = Dictionary(items:
                manifest.targets.map({ ($0.name, $0 as TargetDescription ) }))
            let foo = targets["foo"]!
            XCTAssertEqual(foo.name, "foo")
            XCTAssertFalse(foo.isTest)
            XCTAssertEqual(foo.dependencies, ["dep1", .product(name: "product"), .target(name: "target")])

            let bar = targets["bar"]!
            XCTAssertEqual(bar.name, "bar")
            XCTAssertTrue(bar.isTest)
            XCTAssertEqual(bar.dependencies, ["foo"])

            // Check dependencies.
            let deps = Dictionary(items: manifest.dependencies.map{ ($0.url, $0) })
            XCTAssertEqual(deps["/foo1"], PackageDependencyDescription(url: "/foo1", requirement: .upToNextMajor(from: "1.0.0")))

            // Check products.
            let products = Dictionary(items: manifest.products.map{ ($0.name, $0) })

            let tool = products["tool"]!
            XCTAssertEqual(tool.name, "tool")
            XCTAssertEqual(tool.targets, ["tool"])
            XCTAssertEqual(tool.type, .executable)

            let fooProduct = products["Foo"]!
            XCTAssertEqual(fooProduct.name, "Foo")
            XCTAssertEqual(fooProduct.type, .library(.automatic))
            XCTAssertEqual(fooProduct.targets, ["Foo"])
        }
    }

    func testSwiftLanguageVersion() throws {
        var stream = BufferedOutputByteStream()
        stream <<< """
            import PackageDescription
            let package = Package(
               name: "Foo",
               swiftLanguageVersions: [.v4, .v4_2, .v5]
            )
            """

        loadManifest(stream.bytes) { manifest in
            XCTAssertEqual(manifest.swiftLanguageVersions, [.v4, .v4_2, .v5])
        }

        stream = BufferedOutputByteStream()
        stream <<< """
            import PackageDescription
            let package = Package(
               name: "Foo",
               swiftLanguageVersions: [.v3]
            )
            """

        do {
            try loadManifestThrowing(stream.bytes) { _ in }
            XCTFail()
        } catch {
            guard case let ManifestParseError.invalidManifestFormat(message, _) = error else {
                return XCTFail("\(error)")
            }

            XCTAssertMatch(message, .contains("'v3' is unavailable"))
            XCTAssertMatch(message, .contains("'v3' was obsoleted in PackageDescription 5"))
        }
    }

    func testPlatforms() throws {
        // Sanity check.
        var stream = BufferedOutputByteStream()
        stream <<< """
            import PackageDescription
            let package = Package(
               name: "Foo",
               platforms: [
                   .macOS(.v10_13), .iOS("12.2"),
                   .tvOS(.v12), .watchOS(.v3),
               ]
            )
            """

        loadManifest(stream.bytes) { manifest in
            XCTAssertEqual(manifest.platforms, [
                PlatformDescription(name: "macos", version: "10.13"),
                PlatformDescription(name: "ios", version: "12.2"),
                PlatformDescription(name: "tvos", version: "12.0"),
                PlatformDescription(name: "watchos", version: "3.0"),
            ])
        }

        // Test invalid custom versions.
        stream = BufferedOutputByteStream()
        stream <<< """
            import PackageDescription
            let package = Package(
               name: "Foo",
               platforms: [
                   .macOS("-11.2"), .iOS("12.x.2"), .tvOS("10..2"), .watchOS("1.0"),
               ]
            )
            """

        do {
            try loadManifestThrowing(stream.bytes) { _ in }
            XCTFail("Unexpected success")
        } catch ManifestParseError.runtimeManifestErrors(let errors) {
            XCTAssertEqual(errors, ["invalid macOS version string: -11.2", "invalid iOS version string: 12.x.2", "invalid tvOS version string: 10..2", "invalid watchOS version string: 1.0"])
        }

        // Duplicates.
        stream = BufferedOutputByteStream()
        stream <<< """
            import PackageDescription
            let package = Package(
               name: "Foo",
               platforms: [
                   .macOS(.v10_10), .macOS(.v10_12),
               ]
            )
            """

        do {
            try loadManifestThrowing(stream.bytes) { _ in }
            XCTFail("Unexpected success")
        } catch ManifestParseError.runtimeManifestErrors(let errors) {
            XCTAssertEqual(errors, ["found multiple declaration for the platform: macos"])
        }

        // Empty.
        stream = BufferedOutputByteStream()
        stream <<< """
            import PackageDescription
            let package = Package(
               name: "Foo",
               platforms: []
            )
            """

        do {
            try loadManifestThrowing(stream.bytes) { _ in }
            XCTFail("Unexpected success")
        } catch ManifestParseError.runtimeManifestErrors(let errors) {
            XCTAssertEqual(errors, ["supported platforms can't be empty"])
        }

        // Newer OS version.
        stream = BufferedOutputByteStream()
        stream <<< """
            import PackageDescription
            let package = Package(
               name: "Foo",
               platforms: [
                   .macOS(.v10_15), .iOS(.v13),
               ]
            )
            """

        do {
            try loadManifestThrowing(stream.bytes) { _ in }
            XCTFail("Unexpected success")
        } catch {
            guard case let ManifestParseError.invalidManifestFormat(message, _) = error else {
                return XCTFail("\(error)")
            }

            XCTAssertMatch(message, .contains("error: 'v10_15' is unavailable"))
            XCTAssertMatch(message, .contains("note: 'v10_15' was introduced in PackageDescription 5.1"))
            XCTAssertMatch(message, .contains("note: 'v13' was introduced in PackageDescription 5.1"))
        }
    }

    func testBuildSettings() throws {
        let stream = BufferedOutputByteStream()
        stream <<< """
            import PackageDescription
            let package = Package(
               name: "Foo",
               targets: [
                   .target(
                       name: "Foo",
                       cSettings: [
                           .headerSearchPath("path/to/foo"),
                           .define("C", .when(platforms: [.linux])),
                           .define("CC", to: "4", .when(platforms: [.linux], configuration: .release)),
                       ],
                       cxxSettings: [
                           .headerSearchPath("path/to/bar"),
                           .define("CXX"),
                       ],
                       swiftSettings: [
                           .define("SWIFT", .when(configuration: .release)),
                           .define("SWIFT_DEBUG", .when(platforms: [.watchOS], configuration: .debug)),
                       ],
                       linkerSettings: [
                           .linkedLibrary("libz"),
                           .linkedFramework("CoreData", .when(platforms: [.macOS, .tvOS])),
                       ]
                   ),
               ]
            )
            """

        loadManifest(stream.bytes) { manifest in
            let settings = manifest.targets[0].settings

            XCTAssertEqual(settings[0], .init(tool: .c, name: .headerSearchPath, value: ["path/to/foo"]))
            XCTAssertEqual(settings[1], .init(tool: .c, name: .define, value: ["C"], condition: .init(platformNames: ["linux"])))
            XCTAssertEqual(settings[2], .init(tool: .c, name: .define, value: ["CC=4"], condition: .init(platformNames: ["linux"], config: "release")))

            XCTAssertEqual(settings[3], .init(tool: .cxx, name: .headerSearchPath, value: ["path/to/bar"]))
            XCTAssertEqual(settings[4], .init(tool: .cxx, name: .define, value: ["CXX"]))

            XCTAssertEqual(settings[5], .init(tool: .swift, name: .define, value: ["SWIFT"], condition: .init(config: "release")))
            XCTAssertEqual(settings[6], .init(tool: .swift, name: .define, value: ["SWIFT_DEBUG"], condition: .init(platformNames: ["watchos"], config: "debug")))

            XCTAssertEqual(settings[7], .init(tool: .linker, name: .linkedLibrary, value: ["libz"]))
            XCTAssertEqual(settings[8], .init(tool: .linker, name: .linkedFramework, value: ["CoreData"], condition: .init(platformNames: ["macos", "tvos"])))
        }
    }

    func testSerializedDiagnostics() throws {
        mktmpdir { path in
            let fs = localFileSystem

            let manifestPath = path.appending(components: "pkg", "Package.swift")
            try fs.writeFileContents(manifestPath) { stream in
                stream <<< """
                import PackageDescription
                let package = Package(
                name: "Trivial",
                    targets: [
                        .target(
                            name: "foo",
                            dependencies: []),

                )
                """
            }

            let loader = ManifestLoader(
                manifestResources: Resources.default,
                serializedDiagnostics: true, cacheDir: path)

            do {
                _ = try loader.load(
                    package: manifestPath.parentDirectory,
                    baseURL: manifestPath.pathString,
                    manifestVersion: .v5)
            } catch ManifestParseError.invalidManifestFormat(let error, let diagnosticFile) {
                XCTAssertMatch(error, .contains("expected \')\' in expression list"))
                let contents = try localFileSystem.readFileContents(diagnosticFile!)
                XCTAssertNotNil(contents)
            }

            try fs.writeFileContents(manifestPath) { stream in
                stream <<< """
                import PackageDescription
                func foo() {
                    let a = 5
                }
                let package = Package(
                    name: "Trivial",
                    targets: [
                        .target(
                            name: "foo",
                            dependencies: []),
                    ]
                )
                """
            }

            let diagnostics = DiagnosticsEngine()
            _ = try loader.load(
                package: manifestPath.parentDirectory,
                baseURL: manifestPath.pathString,
                manifestVersion: .v5,
                diagnostics: diagnostics
            )

            guard let diag = diagnostics.diagnostics.first?.message.data as? ManifestLoadingDiagnostic else {
                return XCTFail("Expected a diagnostic")
            }
            XCTAssertMatch(diag.output, .contains("warning: initialization of immutable value"))
            let contents = try localFileSystem.readFileContents(diag.diagnosticFile!)
            XCTAssertNotNil(contents)
        }
    }

    func testInvalidBuildSettings() throws {
        var stream = BufferedOutputByteStream()
        stream <<< """
            import PackageDescription
            let package = Package(
               name: "Foo",
               targets: [
                   .target(
                       name: "Foo",
                       cSettings: [
                           .headerSearchPath("$(BYE)/path/to/foo/$(SRCROOT)/$(HELLO)"),
                       ]
                   ),
               ]
            )
            """

        do {
            try loadManifestThrowing(stream.bytes) { _ in }
            XCTFail("Unexpected success")
        } catch ManifestParseError.runtimeManifestErrors(let errors) {
            XCTAssertEqual(errors, ["the build setting 'headerSearchPath' contains invalid component(s): $(BYE) $(SRCROOT) $(HELLO)"])
        }

        stream = BufferedOutputByteStream()
        stream <<< """
            import PackageDescription
            let package = Package(
               name: "Foo",
               targets: [
                   .target(
                       name: "Foo",
                       cSettings: []
                   ),
               ]
            )
            """

        do {
            try loadManifestThrowing(stream.bytes) { _ in }
            XCTFail("Unexpected success")
        } catch ManifestParseError.runtimeManifestErrors(let errors) {
            XCTAssertEqual(errors, ["cSettings cannot be an empty array; provide at least one setting or remove it"])
        }
    }

    func testWindowsPlatform() throws {
        var stream = BufferedOutputByteStream()
        stream <<< """
            import PackageDescription
            let package = Package(
               name: "Foo",
               targets: [
                   .target(
                       name: "Foo",
                       cSettings: [
                           .define("LLVM_ON_WIN32", .when(platforms: [.windows])),
                       ]
                   ),
               ]
            )
            """

        do {
            try loadManifestThrowing(stream.bytes) { _ in }
            XCTFail("Unexpected success")
        } catch ManifestParseError.runtimeManifestErrors(let errors) {
            XCTAssertEqual(errors, ["failed to load the Windows platform"])
        }
    }
}
