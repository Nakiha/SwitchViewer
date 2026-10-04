#!/usr/bin/env python3
"""Generate the checked-in Xcode project without third-party build tools."""
from pathlib import Path
import hashlib
import re
import json

root = Path(__file__).resolve().parent.parent
version = json.loads((root / 'Version.json').read_text())
project = root / 'iPad/SwitchViewerIPad.xcodeproj'
project.mkdir(parents=True, exist_ok=True)
existing = project / 'project.pbxproj'
previous = existing.read_text() if existing.exists() else ''
# Preserve the local signing choice made in Xcode during project regeneration.
team_match = re.search(r'DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]+)', previous)
bundle_match = re.search(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+)', previous)
team = team_match.group(1) if team_match else None
bundle = bundle_match.group(1).strip() if bundle_match else 'com.zhu.switchviewer.ipad'

def uid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

def ref(name):
    return uid(name)

local = sorted(p.name for p in (root / 'iPad/SwitchViewerIPad').glob('*.swift'))
shared = ['AppleDownsampledFrameInterpolator.swift', 'NV12Scaler.swift',
          'FrameProcessorSessionCleanup.swift', 'SourceFrameRateCounter.swift',
          'SwitchFrameCadenceDetector.swift', 'ContentFrameCadenceDetector.swift', 'TimedFrameQueue.swift', 'CaptureVideoFormat.swift']
files = [(name, f'SwitchViewerIPad/{name}') for name in local]
files += [(name, f'../Sources/SwitchViewerInterpolation/{name}') for name in shared]
lines = ['// !$*UTF8*$!', '{', 'archiveVersion = 1;', 'classes = {};', 'objectVersion = 56;', 'objects = {']
for name, path in files:
    lines += [f'{ref("file:"+name)} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path}"; sourceTree = "<group>"; }};',
              f'{ref("build:"+name)} = {{isa = PBXBuildFile; fileRef = {ref("file:"+name)}; }};']
lines += [f'{ref("plist")} = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = SwitchViewerIPad/Info.plist; sourceTree = "<group>"; }};',
          f'{ref("app")} = {{isa = PBXFileReference; explicitFileType = wrapper.application; path = SwitchViewerIPad.app; sourceTree = BUILT_PRODUCTS_DIR; }};',
          f'{ref("sources")} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (' + ','.join(ref('build:'+name) for name,_ in files) + '); runOnlyForDeploymentPostprocessing = 0; };',
          f'{ref("frameworks")} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};',
          f'{ref("resources")} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};',
          f'{ref("products")} = {{isa = PBXGroup; children = ({ref("app")}); name = Products; sourceTree = "<group>"; }};',
          f'{ref("main")} = {{isa = PBXGroup; children = (' + ','.join(ref('file:'+name) for name,_ in files) + f',{ref("plist")},{ref("products")}); sourceTree = "<group>"; }};',
          f'{ref("target")} = {{isa = PBXNativeTarget; buildConfigurationList = {ref("targetconfigs")}; buildPhases = ({ref("sources")},{ref("frameworks")},{ref("resources")}); buildRules = (); dependencies = (); name = SwitchViewerIPad; productName = SwitchViewerIPad; productReference = {ref("app")}; productType = "com.apple.product-type.application"; }};',
          f'{ref("project")} = {{isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; TargetAttributes = {{{ref("target")} = {{CreatedOnToolsVersion = 27.0; }}; }}; }}; buildConfigurationList = {ref("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh-Hans; hasScannedForEncodings = 0; knownRegions = (en, Base, "zh-Hans"); mainGroup = {ref("main")}; productRefGroup = {ref("products")}; projectDirPath = ""; projectRoot = ""; targets = ({ref("target")}); }};']
for kind in ['project', 'target']:
    for mode in ['Debug', 'Release']:
        settings = {
            'CLANG_ENABLE_MODULES': 'YES', 'SDKROOT': 'iphoneos', 'IPHONEOS_DEPLOYMENT_TARGET': '26.0',
            'SWIFT_VERSION': '5.0', 'SWIFT_OPTIMIZATION_LEVEL': '"-Onone"' if mode=='Debug' else '"-O"',
            'DEBUG_INFORMATION_FORMAT': 'dwarf' if mode=='Debug' else '"dwarf-with-dsym"',
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG' if mode=='Debug' else '""',
        }
        if kind == 'target':
            settings.update({'PRODUCT_BUNDLE_IDENTIFIER': bundle,
                             'PRODUCT_NAME': '"$(TARGET_NAME)"',
                             'MARKETING_VERSION': version['version'], 'CURRENT_PROJECT_VERSION': str(version['build']), 'INFOPLIST_FILE': 'SwitchViewerIPad/Info.plist',
                             'GENERATE_INFOPLIST_FILE': 'NO', 'TARGETED_DEVICE_FAMILY': '2',
                             'SUPPORTED_PLATFORMS': '"iphoneos iphonesimulator"',
                             'SUPPORTS_MACCATALYST': 'NO', 'CODE_SIGN_STYLE': 'Automatic',
                             'LD_RUNPATH_SEARCH_PATHS': '"$(inherited) @executable_path/Frameworks"',
                             'ENABLE_USER_SCRIPT_SANDBOXING': 'YES'})
        if kind == 'target' and team:
            settings['DEVELOPMENT_TEAM'] = team
        lines += [f'{ref(kind+mode)} = {{isa = XCBuildConfiguration; buildSettings = {{' + ''.join(f'{k} = {v};' for k,v in settings.items()) + f'}}; name = {mode}; }};']
    lines += [f'{ref(kind+"configs")} = {{isa = XCConfigurationList; buildConfigurations = ({ref(kind+"Debug")},{ref(kind+"Release")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};']
lines += ['};', f'rootObject = {ref("project")};', '}']
(project / 'project.pbxproj').write_text('\n'.join(lines)+'\n')
scheme = project / 'xcshareddata/xcschemes/SwitchViewerIPad.xcscheme'
scheme.parent.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref("target")}" BuildableName="SwitchViewerIPad.app" BlueprintName="SwitchViewerIPad" ReferencedContainer="container:SwitchViewerIPad.xcodeproj"/>'
scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(project)
