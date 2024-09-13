// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2016 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//

#if NS_FOUNDATION_ALLOWS_TESTABLE_IMPORT
    #if canImport(SwiftFoundation) && !DEPLOYMENT_RUNTIME_OBJC
        @testable import SwiftFoundation
    #else
        @testable import Foundation
    #endif
#endif

internal func testBundle(executable: Bool = false) -> Bundle {
    #if DARWIN_COMPATIBILITY_TESTS
    for bundle in Bundle.allBundles {
        if let bundleId = bundle.bundleIdentifier, bundleId == "org.swift.DarwinCompatibilityTests", bundle.resourcePath != nil {
            return bundle
        }
    }
    fatalError("Cant find test bundle")
    #else
    return executable ? Bundle.main : Bundle.module
    #endif
}


#if DARWIN_COMPATIBILITY_TESTS
extension Bundle {
    static let _supportsFreestandingBundles = false
    static let _supportsFHSBundles = false
}
#endif


internal func testBundleName() -> String {
    // Either 'TestFoundation' or 'DarwinCompatibilityTests'
    return testBundle().infoDictionary!["CFBundleName"] as! String
}

internal func xdgTestHelperURL() throws -> URL {
    #if os(Android)
    throw XCTSkip("xdgTestHelper not yet supported on Android")
    #endif

    #if os(Windows)
    // Adding the xdgTestHelper as a dependency of TestFoundation causes its object files (including the main function) to be linked into the test runner executable as well
    // While this works on Linux due to special linker functionality, this doesn't work on Windows and results in a collision between the two main symbols
    // SwiftPM also cannot support depending on this executable (to ensure it is built) without also linking its objects into the test runner
    // For those reasons, using the xdgTestHelper on Windows is currently unsupported and tests that rely on it must be skipped
    throw XCTSkip("xdgTestHelper is not supported during testing on Windows (test executables are not supported by SwiftPM on Windows)")
    #else
    testBundle().bundleURL.deletingLastPathComponent().appendingPathComponent("xdgTestHelper")
    #endif
}


class BundlePlayground {
    enum ExecutableType: CaseIterable {
        case library
        case executable
        
        var pathExtension: String? {
            switch self {
            case .library:
                #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
                return "dylib"
                #elseif os(Windows)
                return "dll"
                #else
                return "so"
                #endif
            case .executable:
                #if os(Windows)
                return "exe"
                #else
                return nil
                #endif
            }
        }

        var fileNameSuffix: String? {
            #if os(Windows) && DEBUG
            "_debug"
            #else
            nil
            #endif
        }
        
        var flatPathExtension: String? {
            #if os(Windows)
            return self.pathExtension
            #else
            return nil
            #endif
        }
        
        var fhsPrefix: String {
            switch self {
            case .executable:
                return "bin"
            case .library:
                return "lib"
            }
        }
        
        var nonFlatFilePrefix: String {
            switch self {
            case .executable:
                return ""
            case .library:
#if os(Windows)
                return ""
#else
                return "lib"
#endif
            }
        }
    }
    
    enum Layout {
        case flat(ExecutableType)
        case fhs(ExecutableType)
        case freestanding(ExecutableType)
        
        static var allApplicable: [Layout] {
            let layouts: [Layout] = [
                .flat(.library),
                .flat(.executable),
                .fhs(.library),
                .fhs(.executable),
                .freestanding(.library),
                .freestanding(.executable),
            ]
            
            return layouts.filter { $0.isSupported }
        }
            
        var isFreestanding: Bool {
            switch self {
            case .freestanding(_):
                return true
            default:
                return false
            }
        }
        
        var isFHS: Bool {
            switch self {
            case .fhs(_):
                return true
            default:
                return false
            }
        }
        
        var isFlat: Bool {
            switch self {
            case .flat(_):
                return true
            default:
                return false
            }
        }
        
        var isSupported: Bool {
            switch self {
            case .flat(_):
                return true
            case .freestanding(_):
                return Bundle._supportsFreestandingBundles
            case .fhs(_):
                return Bundle._supportsFHSBundles
            }
        }
    }
    
    let bundleName: String
    let bundleExtension: String
    let resourceFilenames: [String]
    let resourceSubdirectory: String
    let subdirectoryResourcesFilenames: [String]
    let auxiliaryExecutableName: String
    let layout: Layout
    
    private(set) var bundlePath: String!
    private(set) var mainExecutableURL: URL!
    private var playgroundPath: String?
    
    init?(bundleName: String,
          bundleExtension: String,
          resourceFilenames: [String],
          resourceSubdirectory: String,
          subdirectoryResourcesFilenames: [String],
          auxiliaryExecutableName: String,
          layout: Layout) {
        self.bundleName = bundleName
        self.bundleExtension = bundleExtension
        self.resourceFilenames = resourceFilenames
        self.resourceSubdirectory = resourceSubdirectory
        self.subdirectoryResourcesFilenames = subdirectoryResourcesFilenames
        self.auxiliaryExecutableName = auxiliaryExecutableName
        self.layout = layout
        
        if !_create() {
            destroy()
            return nil
        }
    }
    
    private func _create() -> Bool {
        // Make sure the directory is uniquely named
        
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("TestFoundation_Playground_" + UUID().uuidString)
        
        switch layout {
        case .flat(let executableType):
            do {
                try FileManager.default.createDirectory(atPath: temporaryDirectory.path, withIntermediateDirectories: false, attributes: nil)
                
                // Make a flat bundle in the playground
                let bundleURL = temporaryDirectory.appendingPathComponent(bundleName).appendingPathExtension(self.bundleExtension)
                try FileManager.default.createDirectory(atPath: bundleURL.path, withIntermediateDirectories: false, attributes: nil)
                
                // Make a main and an auxiliary executable:
                self.mainExecutableURL = bundleURL
                    .appendingPathComponent(bundleName + (executableType.fileNameSuffix ?? ""))
                
                if let ext = executableType.flatPathExtension {
                    self.mainExecutableURL.appendPathExtension(ext)
                }
                
                guard FileManager.default.createFile(atPath: mainExecutableURL.path, contents: nil) else {
                    return false
                }
                
                var auxiliaryExecutableURL = bundleURL
                    .appendingPathComponent(auxiliaryExecutableName + (executableType.fileNameSuffix ?? ""))
                
                if let ext = executableType.flatPathExtension {
                    auxiliaryExecutableURL.appendPathExtension(ext)
                }
                
                guard FileManager.default.createFile(atPath: auxiliaryExecutableURL.path, contents: nil) else {
                    return false
                }
                
                // Put some resources in the bundle
                for resourceName in resourceFilenames {
                    guard FileManager.default.createFile(atPath: bundleURL.appendingPathComponent(resourceName).path, contents: nil, attributes: nil) else {
                        return false
                    }
                }
                
                // Add a resource into a subdirectory
                let subdirectoryURL = bundleURL.appendingPathComponent(resourceSubdirectory)
                try FileManager.default.createDirectory(atPath: subdirectoryURL.path, withIntermediateDirectories: false, attributes: nil)
                
                for resourceName in subdirectoryResourcesFilenames {
                    guard FileManager.default.createFile(atPath: subdirectoryURL.appendingPathComponent(resourceName).path, contents: nil, attributes: nil) else {
                        return false
                    }
                }
                
                self.bundlePath = bundleURL.path
            } catch {
                return false
            }
            
        case .fhs(let executableType):
            do {
                
                // Create a FHS /usr/local-style hierarchy:
                try FileManager.default.createDirectory(atPath: temporaryDirectory.path, withIntermediateDirectories: false, attributes: nil)
                try FileManager.default.createDirectory(atPath: temporaryDirectory.appendingPathComponent("share").path, withIntermediateDirectories: false, attributes: nil)
                try FileManager.default.createDirectory(atPath: temporaryDirectory.appendingPathComponent("lib").path, withIntermediateDirectories: false, attributes: nil)
                
                // Make a main and an auxiliary executable:
                self.mainExecutableURL = temporaryDirectory
                    .appendingPathComponent(executableType.fhsPrefix)
                    .appendingPathComponent(executableType.nonFlatFilePrefix + bundleName + (executableType.fileNameSuffix ?? ""))
                
                if let ext = executableType.pathExtension {
                    self.mainExecutableURL.appendPathExtension(ext)
                }
                guard FileManager.default.createFile(atPath: mainExecutableURL.path, contents: nil) else { return false }
                
                let executablesDirectory = temporaryDirectory.appendingPathComponent("libexec").appendingPathComponent("\(bundleName).executables")
                try FileManager.default.createDirectory(atPath: executablesDirectory.path, withIntermediateDirectories: true, attributes: nil)
                var auxiliaryExecutableURL = executablesDirectory
                    .appendingPathComponent(executableType.nonFlatFilePrefix + auxiliaryExecutableName + (executableType.fileNameSuffix ?? ""))
                
                if let ext = executableType.pathExtension {
                    auxiliaryExecutableURL.appendPathExtension(ext)
                }
                guard FileManager.default.createFile(atPath: auxiliaryExecutableURL.path, contents: nil) else { return false }
                
                // Make a .resources directory in …/share:
                let resourcesDirectory = temporaryDirectory.appendingPathComponent("share").appendingPathComponent("\(bundleName).resources")
                try FileManager.default.createDirectory(atPath: resourcesDirectory.path, withIntermediateDirectories: false, attributes: nil)
                
                // Put some resources in the bundle
                for resourceName in resourceFilenames {
                    guard FileManager.default.createFile(atPath: resourcesDirectory.appendingPathComponent(resourceName).path, contents: nil, attributes: nil) else { return false }
                }
                
                // Add a resource into a subdirectory
                let subdirectoryURL = resourcesDirectory.appendingPathComponent(resourceSubdirectory)
                try FileManager.default.createDirectory(atPath: subdirectoryURL.path, withIntermediateDirectories: false, attributes: nil)
                
                for resourceName in subdirectoryResourcesFilenames {
                    guard FileManager.default.createFile(atPath: subdirectoryURL.appendingPathComponent(resourceName).path, contents: nil, attributes: nil) else { return false }
                }
                
                self.bundlePath = resourcesDirectory.path
            } catch {
                return false
            }
            
        case .freestanding(let executableType):
            do {
                let bundleName = URL(string:self.bundleName)!.deletingPathExtension().path
                
                try FileManager.default.createDirectory(atPath: temporaryDirectory.path, withIntermediateDirectories: false, attributes: nil)
                
                // Make a main executable:
                self.mainExecutableURL = temporaryDirectory
                    .appendingPathComponent(executableType.nonFlatFilePrefix + bundleName + (executableType.fileNameSuffix ?? ""))
                
                if let ext = executableType.pathExtension {
                    self.mainExecutableURL.appendPathExtension(ext)
                }
                guard FileManager.default.createFile(atPath: mainExecutableURL.path, contents: nil) else { return false }
                
                // Make a .resources directory:
                let resourcesDirectory = temporaryDirectory.appendingPathComponent("\(bundleName).resources")
                try FileManager.default.createDirectory(atPath: resourcesDirectory.path, withIntermediateDirectories: false, attributes: nil)
                
                // Make an auxiliary executable:
                var auxiliaryExecutableURL = resourcesDirectory
                    .appendingPathComponent(executableType.nonFlatFilePrefix + auxiliaryExecutableName + (executableType.fileNameSuffix ?? ""))
                if let ext = executableType.pathExtension {
                    auxiliaryExecutableURL.appendPathExtension(ext)
                }
                guard FileManager.default.createFile(atPath: auxiliaryExecutableURL.path, contents: nil) else { return false }
                
                // Put some resources in the bundle
                for resourceName in resourceFilenames {
                    guard FileManager.default.createFile(atPath: resourcesDirectory.appendingPathComponent(resourceName).path, contents: nil, attributes: nil) else { return false }
                }
                
                // Add a resource into a subdirectory
                let subdirectoryURL = resourcesDirectory.appendingPathComponent(resourceSubdirectory)
                try FileManager.default.createDirectory(atPath: subdirectoryURL.path, withIntermediateDirectories: false, attributes: nil)
                
                for resourceName in subdirectoryResourcesFilenames {
                    guard FileManager.default.createFile(atPath: subdirectoryURL.appendingPathComponent(resourceName).path, contents: nil, attributes: nil) else { return false }
                }
                
                self.bundlePath = resourcesDirectory.path
            } catch {
                return false
            }
        }
        
        self.playgroundPath = temporaryDirectory.path
        return true
    }
    
    func destroy() {
        guard let path = self.playgroundPath else { return }
        self.playgroundPath = nil

        try? FileManager.default.removeItem(atPath: path)
    }
    
    deinit {
        assert(playgroundPath == nil, "All playgrounds should have .destroy() invoked on them before they go out of scope.")
    }
}

class TestBundle : XCTestCase {

    func test_paths() {
        let bundle = testBundle()
        
        // bundlePath
        XCTAssert(!bundle.bundlePath.isEmpty)
        XCTAssertEqual(bundle.bundleURL.path, bundle.bundlePath)
        let path = bundle.bundlePath
        
        // etc
        #if os(macOS)
        XCTAssertEqual("\(path)/Contents/Resources", bundle.resourcePath)
        #if DARWIN_COMPATIBILITY_TESTS
        XCTAssertEqual("\(path)/Contents/MacOS/DarwinCompatibilityTests", bundle.executablePath)
        #else
        XCTAssertEqual("\(path)/Contents/MacOS/TestFoundation", bundle.executablePath)
        #endif
        XCTAssertEqual("\(path)/Contents/Frameworks", bundle.privateFrameworksPath)
        XCTAssertEqual("\(path)/Contents/SharedFrameworks", bundle.sharedFrameworksPath)
        XCTAssertEqual("\(path)/Contents/SharedSupport", bundle.sharedSupportPath)
        #endif
        
        XCTAssertNil(bundle.path(forAuxiliaryExecutable: "no_such_file"))
        #if !DARWIN_COMPATIBILITY_TESTS
        XCTAssertNil(bundle.appStoreReceiptURL)
        #endif
    }
    
    func test_resources() {
        let bundle = testBundle()
        
        // bad resources
        XCTAssertNil(bundle.url(forResource: nil, withExtension: nil, subdirectory: nil))
        XCTAssertNil(bundle.url(forResource: "", withExtension: "", subdirectory: nil))
        XCTAssertNil(bundle.url(forResource: "no_such_file", withExtension: nil, subdirectory: nil))
        
        // test file
        let testPlist = bundle.url(forResource: "Test", withExtension: "plist")
        XCTAssertNotNil(testPlist)
        XCTAssertEqual("Test.plist", testPlist!.lastPathComponent)
        XCTAssert(FileManager.default.fileExists(atPath: testPlist!.path))
        
        // aliases, paths
        XCTAssertEqual(testPlist!.path, bundle.url(forResource: "Test", withExtension: "plist", subdirectory: nil)!.path)
        XCTAssertEqual(testPlist!.path, bundle.path(forResource: "Test", ofType: "plist"))
        XCTAssertEqual(testPlist!.path, bundle.path(forResource: "Test", ofType: "plist", inDirectory: nil))
    }
    
    func test_infoPlist() {
        let bundle = testBundle()
        
        // bundleIdentifier
        #if DARWIN_COMPATIBILITY_TESTS
        XCTAssertEqual("org.swift.DarwinCompatibilityTests", bundle.bundleIdentifier)
        #else
        XCTAssertEqual("org.swift.TestFoundation", bundle.bundleIdentifier)
        #endif
        
        // infoDictionary
        let info = bundle.infoDictionary
        XCTAssertNotNil(info)
        
        #if DARWIN_COMPATIBILITY_TESTS
        XCTAssert("DarwinCompatibilityTests" == info!["CFBundleName"] as! String)
        XCTAssert("org.swift.DarwinCompatibilityTests" == info!["CFBundleIdentifier"] as! String)
        #else
        XCTAssert("TestFoundation" == info!["CFBundleName"] as! String)
        XCTAssert("org.swift.TestFoundation" == info!["CFBundleIdentifier"] as! String)
        #endif
        
        // localizedInfoDictionary
        XCTAssertNil(bundle.localizedInfoDictionary) // FIXME: Add a localized Info.plist for testing
    }
    
    func test_localizations() {
        let bundle = testBundle()
        
        XCTAssertEqual(["en"], bundle.localizations)
        XCTAssertEqual(["en"], bundle.preferredLocalizations)
        XCTAssertEqual(["en"], Bundle.preferredLocalizations(from: ["en", "pl", "es"]))
    }
    
    private let _bundleName = "MyBundle"
    private let _bundleExtension = "bundle"
    private let _bundleResourceNames = ["hello.world", "goodbye.world", "swift.org"]
    private let _subDirectory = "Sources"
    private let _main = "main"
    private let _type = "swift"
    private let _auxiliaryExecutable = "auxiliaryExecutable"
    
    private func _setupPlayground(layout: BundlePlayground.Layout) -> BundlePlayground? {
        return BundlePlayground(bundleName: _bundleName,
                                bundleExtension: _bundleExtension,
                                resourceFilenames: _bundleResourceNames,
                                resourceSubdirectory: _subDirectory,
                                subdirectoryResourcesFilenames: [ "\(_main).\(_type)" ],
                                auxiliaryExecutableName: _auxiliaryExecutable,
                                layout: layout)
    }
    
    private func _withEachPlaygroundLayout(execute: (BundlePlayground) throws -> Void) rethrows {
        for layout in BundlePlayground.Layout.allApplicable {
            if let playground = _setupPlayground(layout: layout) {
                try execute(playground)
                playground.destroy()
            }
        }
    }
    
    private func _cleanupPlayground(_ location: String) {
        try? FileManager.default.removeItem(atPath: location)
    }
    
    func test_URLsForResourcesWithExtension() {
        _withEachPlaygroundLayout { (playground) in
            let bundle = Bundle(path: playground.bundlePath)!
            XCTAssertNotNil(bundle)
            
            let worldResources = bundle.urls(forResourcesWithExtension: "world", subdirectory: nil)
            XCTAssertNotNil(worldResources)
            XCTAssertEqual(worldResources?.count, 2)
            
            let path = bundle.path(forResource: _main, ofType: _type, inDirectory: _subDirectory)
            XCTAssertNotNil(path)
        }
    }
    
    func test_bundleLoad() {
        let bundle = testBundle(executable: true)
        let _ = bundle.load()
        XCTAssertTrue(bundle.isLoaded)
    }
    
    func test_bundleLoadWithError() {
        let bundleValid = testBundle(executable: true)
        
        // Test valid load using loadAndReturnError
        do {
            try bundleValid.loadAndReturnError()
        }
        catch{
            XCTFail("should not fail to load")
        }
        
        // This causes a dialog box to appear on Windows which will suspend the tests, so skip testing this on Windows for now
        #if !os(Windows)
        // Executable cannot be located
        try! _withEachPlaygroundLayout { (playground) in
            let bundle = Bundle(path: playground.bundlePath)
            XCTAssertThrowsError(try bundle!.loadAndReturnError())
        }
        #endif
    }
    
    func test_bundleWithInvalidPath() {
        let bundleInvalid = Bundle(path: NSTemporaryDirectory() + "test.playground")
        XCTAssertNil(bundleInvalid)
    }
    
    func test_bundlePreflight() {
        XCTAssertNoThrow(try testBundle(executable: true).preflight())
        
        // Windows DLL bundles are always executable
        #if !os(Windows)
        try! _withEachPlaygroundLayout { (playground) in
            let bundle = Bundle(path: playground.bundlePath)!
            
            // Must throw as the main executable is a dummy empty file.
            XCTAssertThrowsError(try bundle.preflight())
        }
        #endif
    }
    
    func test_bundleFindExecutable() {
        XCTAssertNotNil(testBundle(executable: true).executableURL)
        
        _withEachPlaygroundLayout { (playground) in
            let bundle = Bundle(path: playground.bundlePath)!
            XCTAssertNotNil(bundle.executableURL)
        }
    }

    func test_bundleFindAuxiliaryExecutables() {
        _withEachPlaygroundLayout { (playground) in
            let bundle = Bundle(path: playground.bundlePath)!
            XCTAssertNotNil(bundle.url(forAuxiliaryExecutable: _auxiliaryExecutable))
            XCTAssertNil(bundle.url(forAuxiliaryExecutable: "does_not_exist_at_all"))
        }
    }

#if NS_FOUNDATION_ALLOWS_TESTABLE_IMPORT
    func test_bundleReverseBundleLookup() {
        _withEachPlaygroundLayout { (playground) in
            #if !os(Windows)
            if playground.layout.isFreestanding {
                // TODO: Freestanding bundles reverse lookup pending to be implemented on non-Windows platforms.
                return
            }
            #endif
            
            if playground.layout.isFHS {
                // TODO: FHS bundles reverse lookup pending to be implemented on all platforms.
                return
            }
            
            let bundle = Bundle(_executableURL: playground.mainExecutableURL)
            XCTAssertNotNil(bundle)
            XCTAssertEqual(bundle?.bundlePath, playground.bundlePath)
        }
    }

    func test_mainBundleExecutableURL() {
        let maybeURL = Bundle.main.executableURL
        XCTAssertNotNil(maybeURL)
        guard let url = maybeURL else { return }

        let path = url.withUnsafeFileSystemRepresentation {
            String(cString: $0!)
        }
        XCTAssertEqual(path, ProcessInfo.processInfo._processPath)
    }
#endif
    
    func test_bundleForClass() {
        XCTAssertEqual(testBundle(executable: true), Bundle(for: type(of: self)))
    }
}
