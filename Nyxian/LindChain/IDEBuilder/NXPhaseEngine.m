/*
 SPDX-License-Identifier: AGPL-3.0-or-later

 Copyright (C) 2025 - 2026 emexlab

 This file is part of Nyxian.

 Nyxian is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Nyxian is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU Affero General Public License for more details.

 You should have received a copy of the GNU Affero General Public License
 along with Nyxian. If not, see <https://www.gnu.org/licenses/>.
*/

#import <LindChain/IDEBuilder/NXPhaseEngine.h>
#import <LindChain/IDEBuilder/LDEFilesFinder.h>
#import <LindChain/IDEFoundation/NXUtils.h>
#import <LindChain/IDEFoundation/NXBootstrap.h>

@implementation NXPhaseEngine

- (instancetype)initWithProject:(NXProject *)project
                          error:(NSError **)error
{
    /* finding code files */
    NSArray<NSString*> *swiftFiles = LDEFilesFinder(project.url.path, [NSSet setWithArray:@[@"swift"]], [NSSet setWithArray:@[@"Resources",@"Config"]]);
    NSArray<NSString*> *clangFiles = LDEFilesFinder(project.url.path, [NSSet setWithArray:@[@"c",@"cpp",@"m",@"mm"]], [NSSet setWithArray:@[@"Resources",@"Config"]]);
    if(swiftFiles == nil || clangFiles == nil)
    {
        if(error)
        {
            *error = [NSError errorWithDomain:@"org.emexlabs.nyxian.phaseengine" code:0 userInfo:@{ NSLocalizedDescriptionKey: @"Couldn't find code files, unknown error has occured." }];
        }
        return nil;
    }
    if([swiftFiles count] == 0 && [clangFiles count] == 0)
    {
        if(error)
        {
            *error = [NSError errorWithDomain:@"org.emexlabs.nyxian.phaseengine" code:0 userInfo:@{ NSLocalizedDescriptionKey: @"Nothing to build. No code files were found, please create a code file." }];
        }
        return nil;
    }
    
    /* crafting driver flags */
    NSMutableArray *driverFlags = [[NSMutableArray alloc] init];
    if(driverFlags == nil)
    {
        if(error)
        {
            *error = [NSError errorWithDomain:@"org.emexlabs.nyxian.phaseengine" code:0 userInfo:@{ NSLocalizedDescriptionKey: @"Out of memory." }];
        }
        return nil;
    }
    
    [driverFlags addObjectsFromArray:swiftFiles];
    [driverFlags addObjectsFromArray:clangFiles];
    [driverFlags addObject:@"-o"];
    [driverFlags addObject:project.machoURL.path];
    
    /* crafting phase engine */
    if([swiftFiles count] != 0)
    {
        [driverFlags addObjectsFromArray:project.projectConfig.swiftFlags];
        /*
         * the in-process (legacy) swift driver leaves cross-import
         * overlays off, unlike swift-driver; without this, SwiftUI
         * extensions like .photosPicker / .translationTask resolve
         * only with an explicit import of _PhotosUI_SwiftUI etc.
         */
        if(![driverFlags containsObject:@"-enable-cross-import-overlays"])
        {
            /* a FRONTEND option (FrontendOptions.td), not a driver one: the
             * legacy driver rejects it bare and then produces no jobs at all
             * (measured 2026-09-16). */
            [driverFlags addObject:@"-Xfrontend"];
            [driverFlags addObject:@"-enable-cross-import-overlays"];
        }
        /*
         * iOS 27's SDK declares @State, @Model, @AppIntent, #Preview, and
         * every other SDK 27 macro as compiler-plugin macros (SwiftUIMacros,
         * SwiftDataMacros, AppIntentsMacros, ...), not plain attributes.
         * Nyxian's frontend runs in-process, so only in-process LIBRARY
         * plugins work (-load-plugin-library); out-of-process executable
         * plugins (-plugin-path, -external-plugin-path) are not usable on
         * iOS at all.
         *
         * A library plugin ALSO needs -in-process-plugin-server-path or the
         * frontend rejects it outright before ever trying to resolve a
         * macro: PluginLoader::getInProcessPlugins() (lib/AST/
         * PluginLoader.cpp) errors "library plugins require
         * -in-process-plugin-server-path" unless that flag names a real
         * libSwiftInProcPluginServer.dylib. -load-plugin-library alone was
         * never enough.
         *
         * There used to be a second source here: a hand-written
         * NyxianMacros plugin (module "SwiftUIMacros") reimplementing
         * @State alone. DELETED (see the commit that removed
         * NyxianMacros/): it only ever covered 1 of the SDK's 70 macro
         * names, and Apple's own plugin dylibs below supersede it entirely
         * -- correct, for all of them, once installed. No reason to
         * maintain a hand-rolled reimplementation alongside the real
         * thing.
         *
         * Apple's own macro plugin dylibs (SwiftUIMacros, SwiftDataMacros,
         * AppIntentsMacros, PreviewsMacros, ...) are owner-installed at
         * Documents/plugins/*.dylib (never redistributed -- see z97's
         * push-plugins), discovered here at build time, every dylib in the
         * directory passed through, none hardcoded. MEASURED (llvm-objdump
         * on z97, all 15 plugin dylibs -- 12 iPhoneOS + 3 toolchain-level):
         * every one is a macOS-platform Mach-O (LC_BUILD_VERSION
         * platform=macos) -- push-plugins patches that field before
         * copying them over, since iOS dyld enforces platform on load.
         * Distinct, second-order finding: 6 of the 12 iPhoneOS plugins
         * (SwiftUIMacros, AppIntentsMacros, FoundationModelsMacros,
         * MMIOMacros, FinanceMacros, StateReportingMacros) additionally
         * link an absolute macOS-only path (e.g. /System/Library/
         * Frameworks/Foundation.framework/Versions/C/Foundation -- a
         * versioned-bundle path with no equivalent in iOS's flat framework
         * layout) that a platform-stamp patch alone cannot fix; the other 9
         * link only @rpath/lib*.dylib (this app now ships all of those,
         * see stage-in-process-plugin-libs.sh) and /usr/lib/swift/*
         * paths that already exist identically on iOS, so are expected to
         * load once the platform stamp is fixed. All are passed through
         * regardless -- the frontend's own dlopen/dlsym failure per plugin
         * is a more precise, first-hand diagnostic than pre-filtering.
         */
        NSMutableArray<NSString*> *libraryPluginPaths = [NSMutableArray array];

        /*
         * Two places, both owner-installed, never redistributed:
         *
         *   1. this app's own Frameworks directory. Apple's macro plugin dylibs are macOS
         *      Mach-Os whose platform field has to be patched to iOS before dyld will look at
         *      them, and patching invalidates Apple's signature -- iOS then refuses them with
         *      "code signature invalid" (measured 2026-09-17). Injected into the bundle before
         *      installation they are signed with the app itself, so the signature is valid.
         *   2. Documents/plugins, kept as an override for anything dropped in by hand.
         */
        NSURL *pluginsURL = NXBootstrap.shared.pluginsURL;
        NSMutableArray<NSURL*> *installedPlugins = [NSMutableArray array];
        
        NSURL *bundlePluginsURL = NSBundle.mainBundle.privateFrameworksURL;
        for(NSURL *candidate in [NSFileManager.defaultManager contentsOfDirectoryAtURL:bundlePluginsURL includingPropertiesForKeys:nil options:0 error:nil])
        {
            NSString *name = candidate.lastPathComponent;
            if([name hasPrefix:@"lib"] && [name hasSuffix:@"Macros.dylib"])
            {
                [installedPlugins addObject:candidate];
            }
        }
        
        /*
         * Same lib*Macros.dylib filter as the bundle scan above, and for a reason found on
         * 2026-09-17: not every dylib next to the plugins IS a plugin. libAppIntentsMacros
         * links @rpath/libAppIntentSchemas.dylib, a support library Apple ships one directory
         * up from plugins/. It has to travel with the plugins so dyld can resolve it, but
         * handing it to -load-plugin-library would ask the frontend to find macro
         * implementations in a library that has none.
         */
        for(NSURL *candidate in ([NSFileManager.defaultManager contentsOfDirectoryAtURL:pluginsURL includingPropertiesForKeys:nil options:0 error:nil] ?: @[]))
        {
            NSString *name = candidate.lastPathComponent;
            if([name hasPrefix:@"lib"] && [name hasSuffix:@"Macros.dylib"])
            {
                [installedPlugins addObject:candidate];
            }
        }
        if(installedPlugins == nil || installedPlugins.count == 0)
        {
            /*
             * never silent: named here so a build that actually needed one
             * of Apple's SDK 27 macros fails with an explanation pointing
             * at exactly where to put the plugin, not just a bare "external
             * macro implementation type ... could not be found".
             */
            NSLog(@"no macro plugins installed at %@ -- every SDK 27 macro (@State, @Model, @AppIntent, #Preview, ...) will fail to resolve until Apple's plugin dylibs are copied in (see z97's push-plugins)", pluginsURL.path);
        }
        else
        {
            for(NSURL *pluginURL in installedPlugins)
            {
                if([pluginURL.pathExtension isEqualToString:@"dylib"])
                {
                    [libraryPluginPaths addObject:pluginURL.path];
                }
            }
        }

        if(libraryPluginPaths.count != 0)
        {
            /*
             * MEASURED (llvm-objdump-20 --private-headers on
             * CoreCompiler.framework/CoreCompiler, z97, 2026-09-17): its
             * LC_RPATH commands are /usr/lib/swift, @executable_path/
             * Frameworks, and @loader_path/Frameworks -- @loader_path here
             * is CoreCompiler.framework/ itself, so @loader_path/Frameworks
             * resolves to CoreCompiler.framework/Frameworks/, exactly where
             * the existing lib_Compiler*.dylib set (host-compiler-modules'
             * output) is embedded today via the "Embed Libraries" copy
             * phase (dstSubfolderSpec = 10, flattens any source path to
             * just the file's basename in that one directory -- confirmed
             * by inspecting the built IPA, run 35153381480). Apple's plugin
             * dylibs on Documents/plugins depend on @rpath/libSwiftSyntax.
             * dylib etc, which only resolves if a dylib in the active load
             * chain (CoreCompiler's own binary) has that path on its rpath
             * -- so the 13 host-plugin-libs dylibs must live in that same
             * CoreCompiler.framework/Frameworks/ directory, not a
             * CoreCompilerSupportLibs/host-plugin-libs/ subpath (which is
             * only where they sit on SOURCE disk before the copy phase
             * flattens them into the built bundle -- this path expected the
             * pre-copy source layout, not the post-copy bundle layout, and
             * was never reached: verified by unzipping the run 35153381480
             * IPA, this path did not exist).
             */
            NSString *inProcessPluginServerPath = [[NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:@"CoreCompiler.framework/Frameworks/libSwiftInProcPluginServer.dylib"] path];
            if(inProcessPluginServerPath != nil && [NSFileManager.defaultManager fileExistsAtPath:inProcessPluginServerPath])
            {
                [driverFlags addObject:@"-in-process-plugin-server-path"];
                [driverFlags addObject:inProcessPluginServerPath];

                for(NSString *pluginPath in libraryPluginPaths)
                {
                    [driverFlags addObject:@"-load-plugin-library"];
                    [driverFlags addObject:pluginPath];
                }
            }
            else
            {
                /* again: never silent -- name exactly what's missing. */
                NSLog(@"%lu macro plugin(s) found but %@ is missing -- no -in-process-plugin-server-path means the frontend refuses every -load-plugin-library outright, so none of them were passed this build", (unsigned long)libraryPluginPaths.count, inProcessPluginServerPath);
            }
        }

        [driverFlags addObject:@"-module-name"];
        [driverFlags addObject:NXMakeContentCodeFriendly(project.projectConfig.displayName)];
        return [super initWithSwiftFlags:driverFlags withOtherClangFlags:project.projectConfig.compilerFlags withOtherLinkerFlags:project.projectConfig.linkerFlags];
    }
    else
    {
        [driverFlags addObjectsFromArray:project.projectConfig.compilerFlags];
        return [super initWithClangFlags:driverFlags withOtherLinkerFlags:project.projectConfig.linkerFlags];
    }
}

@end
