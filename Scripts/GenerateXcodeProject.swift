// Deterministic native project; app sources stay shared with the Linux SwiftPM build.
import Foundation

let variant = ProcessInfo.processInfo.environment["WRATH_VARIANT"] ?? "modern"
guard ["modern", "compatibility"].contains(variant) else { fatalError("Invalid WRATH_VARIANT") }
let minimumIOS = variant == "compatibility" ? "17.0" : "26.0"
let variantFlag = variant == "compatibility" ? "WRATH_COMPATIBILITY" : ""
let fm = FileManager.default
let infoData = try Data(contentsOf: URL(fileURLWithPath: "Wrath/Info.plist"))
let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
guard let appVersion = info?["CFBundleShortVersionString"] as? String,
    let buildNumber = info?["CFBundleVersion"] as? String
else {
    fatalError("Wrath/Info.plist must specify the app version and build number.")
}
let sources = (fm.enumerator(atPath: "Wrath")?.allObjects as? [String] ?? [])
    .filter { $0.hasSuffix(".swift") }.sorted().map { "Wrath/" + $0 }
func id(_ value: Int) -> String { String(format: "%024X", value) }
var objects: [String] = []
var sourceRefs: [String] = []
var sourceBuilds: [String] = []
for (index, path) in sources.enumerated() {
    let ref = id(100 + index)
    let build = id(200 + index)
    objects.append(
        "\(ref) = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"\(path)\"; sourceTree = SOURCE_ROOT; };"
    )
    objects.append("\(build) = {isa = PBXBuildFile; fileRef = \(ref); };")
    sourceRefs.append(ref)
    sourceBuilds.append(build)
}
let shareSources = (fm.enumerator(atPath: "WrathShare")?.allObjects as? [String] ?? [])
    .filter { $0.hasSuffix(".swift") }.sorted().map { "WrathShare/" + $0 }
var shareRefs: [String] = []
var shareBuilds: [String] = []
for (index, path) in shareSources.enumerated() {
    let ref = id(500 + index)
    let build = id(600 + index)
    objects.append(
        "\(ref) = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"\(path)\"; sourceTree = SOURCE_ROOT; };"
    )
    objects.append("\(build) = {isa = PBXBuildFile; fileRef = \(ref); };")
    shareRefs.append(ref)
    shareBuilds.append(build)
}
let widgetSources = (fm.enumerator(atPath: "WrathLiveActivity/Widget")?.allObjects as? [String] ?? [])
    .filter { $0.hasSuffix(".swift") }.sorted().map { "WrathLiveActivity/Widget/" + $0 }
var widgetRefs: [String] = []
var widgetBuilds: [String] = []
for (index, path) in widgetSources.enumerated() {
    let ref = id(700 + index)
    let build = id(800 + index)
    objects.append(
        "\(ref) = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"\(path)\"; sourceTree = SOURCE_ROOT; };"
    )
    objects.append("\(build) = {isa = PBXBuildFile; fileRef = \(ref); };")
    widgetRefs.append(ref)
    widgetBuilds.append(build)
}
// The Live Activity widget (target 30) shares its attributes with the app through a package library.
objects += [
    "\(id(322)) = {isa = PBXFileReference; explicitFileType = \"wrapper.app-extension\"; path = WrathLiveActivity.appex; sourceTree = BUILT_PRODUCTS_DIR; };",
    "\(id(323)) = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = WrathLiveActivity/Widget/Info.plist; sourceTree = SOURCE_ROOT; };",
    "\(id(318)) = {isa = PBXBuildFile; fileRef = \(id(322)); settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };",
    "\(id(405)) = {isa = XCSwiftPackageProductDependency; package = \(id(400)); productName = WrathActivityShared; };",
    "\(id(319)) = {isa = PBXBuildFile; productRef = \(id(405)); };",
    "\(id(406)) = {isa = XCSwiftPackageProductDependency; package = \(id(400)); productName = WrathActivityShared; };",
    "\(id(324)) = {isa = PBXBuildFile; productRef = \(id(406)); };",
    "\(id(30)) = {isa = PBXNativeTarget; buildConfigurationList = \(id(33)); buildPhases = (\(id(31)), \(id(32))); buildRules = (); dependencies = (); name = WrathLiveActivity; packageProductDependencies = (\(id(406))); productName = WrathLiveActivity; productReference = \(id(322)); productType = \"com.apple.product-type.app-extension\"; };",
    "\(id(31)) = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (\(widgetBuilds.joined(separator: ","))); runOnlyForDeploymentPostprocessing = 0; };",
    "\(id(32)) = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (\(id(324))); runOnlyForDeploymentPostprocessing = 0; };",
    "\(id(33)) = {isa = XCConfigurationList; buildConfigurations = (\(id(34)), \(id(35))); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };",
    "\(id(36)) = {isa = PBXTargetDependency; target = \(id(30)); targetProxy = \(id(37)); };",
    "\(id(37)) = {isa = PBXContainerItemProxy; containerPortal = \(id(1)); proxyType = 1; remoteGlobalIDString = \(id(30)); remoteInfo = WrathLiveActivity; };",
]
// The share extension (target 20) is built first and embedded in Wrath.app/PlugIns.
objects += [
    "\(id(320)) = {isa = PBXFileReference; explicitFileType = \"wrapper.app-extension\"; path = WrathShare.appex; sourceTree = BUILT_PRODUCTS_DIR; };",
    "\(id(321)) = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = WrathShare/Info.plist; sourceTree = SOURCE_ROOT; };",
    "\(id(317)) = {isa = PBXBuildFile; fileRef = \(id(320)); settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };",
    "\(id(404)) = {isa = XCSwiftPackageProductDependency; package = \(id(402)); productName = WrathCore; };",
    "\(id(316)) = {isa = PBXBuildFile; productRef = \(id(404)); };",
    "\(id(8)) = {isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"\"; dstSubfolderSpec = 13; files = (\(id(317)), \(id(318))); name = \"Embed Foundation Extensions\"; runOnlyForDeploymentPostprocessing = 0; };",
    "\(id(20)) = {isa = PBXNativeTarget; buildConfigurationList = \(id(23)); buildPhases = (\(id(21)), \(id(22))); buildRules = (); dependencies = (); name = WrathShare; packageProductDependencies = (\(id(404))); productName = WrathShare; productReference = \(id(320)); productType = \"com.apple.product-type.app-extension\"; };",
    "\(id(21)) = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (\(shareBuilds.joined(separator: ","))); runOnlyForDeploymentPostprocessing = 0; };",
    "\(id(22)) = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (\(id(316))); runOnlyForDeploymentPostprocessing = 0; };",
    "\(id(23)) = {isa = XCConfigurationList; buildConfigurations = (\(id(24)), \(id(25))); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };",
    "\(id(26)) = {isa = PBXTargetDependency; target = \(id(20)); targetProxy = \(id(27)); };",
    "\(id(27)) = {isa = PBXContainerItemProxy; containerPortal = \(id(1)); proxyType = 1; remoteGlobalIDString = \(id(20)); remoteInfo = WrathShare; };",
]
objects += [
    "\(id(302)) = {isa = PBXFileReference; lastKnownFileType = text.xml; path = Wrath/PrivacyInfo.xcprivacy; sourceTree = SOURCE_ROOT; };",
    "\(id(303)) = {isa = PBXBuildFile; fileRef = \(id(302)); };",
    "\(id(304)) = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Wrath/Info.plist; sourceTree = SOURCE_ROOT; };",
    "\(id(305)) = {isa = PBXFileReference; explicitFileType = wrapper.application; path = Wrath.app; sourceTree = BUILT_PRODUCTS_DIR; };",
    "\(id(306)) = {isa = PBXBuildFile; productRef = \(id(401)); };",
    "\(id(307)) = {isa = PBXFileReference; lastKnownFileType = folder; path = Wrath/Resources/wrath_worker; sourceTree = SOURCE_ROOT; };",
    "\(id(308)) = {isa = PBXBuildFile; fileRef = \(id(307)); };",
    "\(id(309)) = {isa = PBXFileReference; lastKnownFileType = folder.iconcomposer.icon; path = AppIcon.icon; sourceTree = SOURCE_ROOT; };",
    "\(id(310)) = {isa = PBXBuildFile; fileRef = \(id(309)); };",
    "\(id(400)) = {isa = XCLocalSwiftPackageReference; relativePath = \".\"; };",
    "\(id(401)) = {isa = XCSwiftPackageProductDependency; package = \(id(400)); productName = WrathBridge; };",
    "\(id(402)) = {isa = XCLocalSwiftPackageReference; relativePath = Core; };",
    "\(id(403)) = {isa = XCSwiftPackageProductDependency; package = \(id(402)); productName = WrathCore; };",
    "\(id(315)) = {isa = PBXBuildFile; productRef = \(id(403)); };",
    "\(id(311)) = {isa = PBXFileReference; lastKnownFileType = folder; path = Wrath/Resources/packages; sourceTree = SOURCE_ROOT; };",
    "\(id(312)) = {isa = PBXBuildFile; fileRef = \(id(311)); };",
    "\(id(313)) = {isa = PBXFileReference; lastKnownFileType = folder; path = Wrath/Resources/Licenses; sourceTree = SOURCE_ROOT; };",
    "\(id(314)) = {isa = PBXBuildFile; fileRef = \(id(313)); };",
    "\(id(1)) = {isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; }; buildConfigurationList = \(id(10)); compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = \(id(2)); productRefGroup = \(id(3)); projectDirPath = \"\"; projectRoot = \"\"; packageReferences = (\(id(400)), \(id(402))); targets = (\(id(4)), \(id(20)), \(id(30))); };",
    "\(id(2)) = {isa = PBXGroup; children = (\((sourceRefs + shareRefs + widgetRefs + [id(302), id(304), id(321), id(323), id(307), id(309), id(311), id(313), id(3)]).joined(separator: ","))); sourceTree = \"<group>\"; };",
    "\(id(3)) = {isa = PBXGroup; children = (\(id(305)), \(id(320)), \(id(322))); name = Products; sourceTree = \"<group>\"; };",
    "\(id(4)) = {isa = PBXNativeTarget; buildConfigurationList = \(id(11)); buildPhases = (\(id(5)), \(id(6)), \(id(7)), \(id(8))); buildRules = (); dependencies = (\(id(26)), \(id(36))); name = Wrath; packageProductDependencies = (\(id(401)), \(id(403)), \(id(405))); productName = Wrath; productReference = \(id(305)); productType = \"com.apple.product-type.application\"; };",
    "\(id(5)) = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (\(sourceBuilds.joined(separator: ","))); runOnlyForDeploymentPostprocessing = 0; };",
    "\(id(6)) = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (\(id(306)), \(id(315)), \(id(319))); runOnlyForDeploymentPostprocessing = 0; };",
    "\(id(7)) = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (\(id(303)), \(id(308)), \(id(310)), \(id(312)), \(id(314))); runOnlyForDeploymentPostprocessing = 0; };",
    "\(id(10)) = {isa = XCConfigurationList; buildConfigurations = (\(id(12)), \(id(13))); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };",
    "\(id(11)) = {isa = XCConfigurationList; buildConfigurations = (\(id(14)), \(id(15))); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };",
]
for (index, name) in ["Debug", "Release"].enumerated() {
    let projectSettings =
        "CLANG_ENABLE_MODULES = YES; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = \(minimumIOS); SWIFT_ACTIVE_COMPILATION_CONDITIONS = \"$(inherited) \(variantFlag) \(index == 0 ? "DEBUG" : "")\"; SWIFT_VERSION = 6.0; SWIFT_OPTIMIZATION_LEVEL = \"\(index == 0 ? "-Onone" : "-O")\"; DEBUG_INFORMATION_FORMAT = \"\(index == 0 ? "dwarf" : "dwarf-with-dsym")\";"
    let appSettings =
        "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = \(buildNumber); GENERATE_INFOPLIST_FILE = YES; INFOPLIST_FILE = Wrath/Info.plist; MARKETING_VERSION = \(appVersion); PRODUCT_BUNDLE_IDENTIFIER = app.wrath.downloader; PRODUCT_NAME = \"$(TARGET_NAME)\"; TARGETED_DEVICE_FAMILY = \"1,2\"; LD_RUNPATH_SEARCH_PATHS = \"$(inherited) @executable_path/Frameworks\"; INFOPLIST_KEY_UILaunchScreen_Generation = YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = \"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight\"; INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = \"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight\";"
    objects.append(
        "\(id(12 + index)) = {isa = XCBuildConfiguration; buildSettings = {\(projectSettings)}; name = \(name); };")
    objects.append(
        "\(id(14 + index)) = {isa = XCBuildConfiguration; buildSettings = {\(appSettings)}; name = \(name); };")
    let shareSettings =
        "CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = \(buildNumber); GENERATE_INFOPLIST_FILE = YES; INFOPLIST_FILE = WrathShare/Info.plist; MARKETING_VERSION = \(appVersion); PRODUCT_BUNDLE_IDENTIFIER = app.wrath.downloader.share; PRODUCT_NAME = \"$(TARGET_NAME)\"; TARGETED_DEVICE_FAMILY = \"1,2\"; SKIP_INSTALL = YES; APPLICATION_EXTENSION_API_ONLY = YES; LD_RUNPATH_SEARCH_PATHS = \"$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks\";"
    objects.append(
        "\(id(24 + index)) = {isa = XCBuildConfiguration; buildSettings = {\(shareSettings)}; name = \(name); };")
    let widgetSettings =
        shareSettings
        .replacingOccurrences(of: "WrathShare/Info.plist", with: "WrathLiveActivity/Widget/Info.plist")
        .replacingOccurrences(of: "app.wrath.downloader.share", with: "app.wrath.downloader.liveactivity")
    objects.append(
        "\(id(34 + index)) = {isa = XCBuildConfiguration; buildSettings = {\(widgetSettings)}; name = \(name); };")

}
try fm.createDirectory(atPath: "Wrath.xcodeproj", withIntermediateDirectories: true)
let project =
    "// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n"
    + objects.joined(separator: "\n") + "\n}; rootObject = \(id(1)); }\n"
try project.write(toFile: "Wrath.xcodeproj/project.pbxproj", atomically: true, encoding: .utf8)
let schemeDir = "Wrath.xcodeproj/xcshareddata/xcschemes"
try fm.createDirectory(atPath: schemeDir, withIntermediateDirectories: true)
let reference =
    "<BuildableReference BuildableIdentifier=\"primary\" BlueprintIdentifier=\"\(id(4))\" BuildableName=\"Wrath.app\" BlueprintName=\"Wrath\" ReferencedContainer=\"container:Wrath.xcodeproj\"/>"
let scheme = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Scheme LastUpgradeVersion="2700" version="1.3">
    <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">\(reference)</BuildActionEntry></BuildActionEntries></BuildAction>
    <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
    <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">\(reference)</BuildableProductRunnable></LaunchAction>
    <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">\(reference)</BuildableProductRunnable></ProfileAction>
    <AnalyzeAction buildConfiguration="Debug"/>
    <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
    </Scheme>
    """
try scheme.write(toFile: schemeDir + "/Wrath.xcscheme", atomically: true, encoding: .utf8)
print(
    "Generated Wrath.xcodeproj with \(sources.count) app, \(shareSources.count) share and \(widgetSources.count) Live Activity Swift files."
)
