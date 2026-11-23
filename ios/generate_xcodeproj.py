#!/usr/bin/env python3
"""Generate a minimal, valid Xcode project (ios/PocketCoffeeApp.xcodeproj) with zero external deps."""

import hashlib
import os

IOS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJ_DIR = os.path.join(IOS_DIR, "PocketCoffeeApp.xcodeproj")
SCHEME_DIR = os.path.join(PROJ_DIR, "xcshareddata", "xcschemes")
os.makedirs(SCHEME_DIR, exist_ok=True)


def uid(seed: str) -> str:
    return hashlib.sha1(seed.encode("utf-8")).hexdigest()[:24].upper()


APP_SOURCES = [
    "PocketCoffeeApp/PocketCoffeeApp.swift",
    "PocketCoffeeApp/AppViewModel.swift",
    "PocketCoffeeApp/NotificationManager.swift",
    "PocketCoffeeApp/ShortcutsIntents.swift",
    "PocketCoffeeApp/Views/IngestTabView.swift",
    "PocketCoffeeApp/Views/ReportsTabView.swift",
    "PocketCoffeeApp/Views/BeansEquipmentTabView.swift",
    "PocketCoffeeApp/Views/OnDeviceAITabView.swift",
    "PocketCoffeeApp/Views/ShortcutsGuideSheet.swift",
    "PocketCoffeeApp/Views/XiaohongshuShareStudioView.swift",
]

INFO_PLIST_PATH = os.path.join(IOS_DIR, "PocketCoffeeApp", "Info.plist")
if not os.path.isfile(INFO_PLIST_PATH):
    with open(INFO_PLIST_PATH, "w", encoding="utf-8") as f:
        f.write("""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>$(DEVELOPMENT_LANGUAGE)</string>
  <key>CFBundleDisplayName</key><string>Pocket Coffee</string>
  <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
  <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$(PRODUCT_NAME)</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
  <key>UILaunchScreen</key><dict/>
  <key>UISupportedInterfaceOrientations</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
  <key>NSCameraUsageDescription</key><string>用于直接拍摄咖啡制作视频与设备介绍画面，全程端侧处理。</string>
  <key>NSMicrophoneUsageDescription</key><string>用于录制制作过程中的语音口述，完成端侧离线转写。</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>用于使用苹果端侧语音识别模型将口述转写为咖啡参数，不上传云端。</string>
  <key>NSPhotoLibraryUsageDescription</key><string>用于从相册选择咖啡制作视频或设备介绍视频进行端侧分析。</string>
  <key>NSLocalNetworkUsageDescription</key><string>可选：用于将端侧生成的咖啡报告同步至局域网内的 Mac 服务。</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><false/>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict>
</plist>
""")

file_refs = []
build_files = []
source_build_ids = []
group_children = []

for rel in APP_SOURCES:
    f_id = uid("fileref:" + rel)
    b_id = uid("buildfile:" + rel)
    name = os.path.basename(rel)
    file_refs.append(f'\t\t{f_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{rel}"; sourceTree = "<group>"; }};')
    build_files.append(f'\t\t{b_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {f_id} /* {name} */; }};')
    source_build_ids.append(f'\t\t\t\t{b_id} /* {name} in Sources */,')
    group_children.append(f'\t\t\t\t{f_id} /* {name} */,')

info_ref_id = uid("fileref:Info.plist")
file_refs.append(f'\t\t{info_ref_id} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "PocketCoffeeApp/Info.plist"; sourceTree = "<group>"; }};')
group_children.append(f'\t\t\t\t{info_ref_id} /* Info.plist */,')

assets_ref_id = uid("fileref:Assets.xcassets")
assets_build_id = uid("buildfile:Assets.xcassets")
file_refs.append(f'\t\t{assets_ref_id} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = "PocketCoffeeApp/Assets.xcassets"; sourceTree = "<group>"; }};')
build_files.append(f'\t\t{assets_build_id} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {assets_ref_id} /* Assets.xcassets */; }};')
group_children.append(f'\t\t\t\t{assets_ref_id} /* Assets.xcassets */,')

app_prod_id = uid("product:PocketCoffeeApp.app")
file_refs.append(f'\t\t{app_prod_id} /* PocketCoffeeApp.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = PocketCoffeeApp.app; sourceTree = BUILT_PRODUCTS_DIR; }};')

pkg_ref_id = uid("localpkg:PocketCoffeeCore")
pkg_prod_id = uid("pkgprod:PocketCoffeeCore")
pkg_build_id = uid("buildfile:PocketCoffeeCore")
build_files.append(f'\t\t{pkg_build_id} /* PocketCoffeeCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {pkg_prod_id} /* PocketCoffeeCore */; }};')

proj_id = uid("project:PocketCoffeeApp")
main_grp_id = uid("group:main")
prod_grp_id = uid("group:products")
app_target_id = uid("target:PocketCoffeeApp")
sources_phase_id = uid("phase:sources")
frameworks_phase_id = uid("phase:frameworks")
resources_phase_id = uid("phase:resources")
proj_cfg_list_id = uid("cfglist:project")
target_cfg_list_id = uid("cfglist:target")
proj_debug_id = uid("cfg:proj:debug")
proj_release_id = uid("cfg:proj:release")
tgt_debug_id = uid("cfg:tgt:debug")
tgt_release_id = uid("cfg:tgt:release")

pbxproj = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
{chr(10).join(build_files)}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{chr(10).join(file_refs)}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{frameworks_phase_id} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{pkg_build_id} /* PocketCoffeeCore in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{main_grp_id} = {{
			isa = PBXGroup;
			children = (
{chr(10).join(group_children)}
				{prod_grp_id} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{prod_grp_id} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{app_prod_id} /* PocketCoffeeApp.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{app_target_id} /* PocketCoffeeApp */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {target_cfg_list_id} /* Build configuration list for PBXNativeTarget "PocketCoffeeApp" */;
			buildPhases = (
				{sources_phase_id} /* Sources */,
				{frameworks_phase_id} /* Frameworks */,
				{resources_phase_id} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = PocketCoffeeApp;
			packageProductDependencies = (
				{pkg_prod_id} /* PocketCoffeeCore */,
			);
			productName = PocketCoffeeApp;
			productReference = {app_prod_id} /* PocketCoffeeApp.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{proj_id} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
				TargetAttributes = {{
					{app_target_id} = {{
						DevelopmentTeam = X855BJ9K77;
						ProvisioningStyle = Automatic;
					}};
				}};
			}};
			buildConfigurationList = {proj_cfg_list_id} /* Build configuration list for PBXProject "PocketCoffeeApp" */;
			compatibilityVersion = "Xcode 15.0";
			developmentRegion = "zh-Hans";
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				"zh-Hans",
				Base,
			);
			mainGroup = {main_grp_id};
			packageReferences = (
				{pkg_ref_id} /* XCLocalSwiftPackageReference "PocketCoffeeCore" */,
			);
			productRefGroup = {prod_grp_id} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{app_target_id} /* PocketCoffeeApp */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{resources_phase_id} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{assets_build_id} /* Assets.xcassets in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{sources_phase_id} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{chr(10).join(source_build_ids)}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{proj_debug_id} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CODE_SIGN_STYLE = Automatic;
				DEVELOPMENT_TEAM = X855BJ9K77;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				SDKROOT = iphoneos;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Debug;
		}};
		{proj_release_id} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CODE_SIGN_STYLE = Automatic;
				DEVELOPMENT_TEAM = X855BJ9K77;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				SDKROOT = iphoneos;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Release;
		}};
		{tgt_debug_id} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = X855BJ9K77;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = PocketCoffeeApp/Info.plist;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.dji.velbent.PocketCoffeeLog;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = iphoneos;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Debug;
		}};
		{tgt_release_id} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = X855BJ9K77;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = PocketCoffeeApp/Info.plist;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.dji.velbent.PocketCoffeeLog;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = iphoneos;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{proj_cfg_list_id} /* Build configuration list for PBXProject "PocketCoffeeApp" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{proj_debug_id} /* Debug */,
				{proj_release_id} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Debug;
		}};
		{target_cfg_list_id} /* Build configuration list for PBXNativeTarget "PocketCoffeeApp" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{tgt_debug_id} /* Debug */,
				{tgt_release_id} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Debug;
		}};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
		{pkg_ref_id} /* XCLocalSwiftPackageReference "PocketCoffeeCore" */ = {{
			isa = XCLocalSwiftPackageReference;
			relativePath = PocketCoffeeCore;
		}};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		{pkg_prod_id} /* PocketCoffeeCore */ = {{
			isa = XCSwiftPackageProductDependency;
			package = {pkg_ref_id} /* XCLocalSwiftPackageReference "PocketCoffeeCore" */;
			productName = PocketCoffeeCore;
		}};
/* End XCSwiftPackageProductDependency section */
	}};
	rootObject = {proj_id} /* Project object */;
}}
"""

with open(os.path.join(PROJ_DIR, "project.pbxproj"), "w", encoding="utf-8") as f:
    f.write(pbxproj)

scheme_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app_target_id}" BuildableName = "PocketCoffeeApp.app" BlueprintName = "PocketCoffeeApp" ReferencedContainer = "container:PocketCoffeeApp.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app_target_id}" BuildableName = "PocketCoffeeApp.app" BlueprintName = "PocketCoffeeApp" ReferencedContainer = "container:PocketCoffeeApp.xcodeproj"/>
      </BuildableProductRunnable>
   </LaunchAction>
</Scheme>
"""

with open(os.path.join(SCHEME_DIR, "PocketCoffeeApp.xcscheme"), "w", encoding="utf-8") as f:
    f.write(scheme_xml)

print("Generated:", PROJ_DIR)
