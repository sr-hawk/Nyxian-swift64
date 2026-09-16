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

#import <LindChain/IDEFoundation/NXBootstrap.h>
#import <LindChain/Utils/Zip.h>
#import <LindChain/Downloader/fdownload.h>
#import <LindChain/ProcEnvironment/Surface/extra/relax.h>
#import <MobileDevelopmentKit/MDKThreadPool.h>
#import <MobileDevelopmentKit/MDKSDK.h>
#import <MobileDevelopmentKit/MDKOSVersion.h>
#import <UI/XCodeButton.h>
#import <Nyxian-Swift.h>

BOOL PEURLIsContainedIn(NSURL *candidate,
                        NSURL *root)
{
    NSURL *candidateSatnderized = candidate.URLByResolvingSymlinksInPath.URLByStandardizingPath;
    NSURL *rootSatnderized = root.URLByResolvingSymlinksInPath.URLByStandardizingPath;
    
    NSString *candidatePath = candidateSatnderized.path;
    NSString *rootPath = rootSatnderized.path;
    
    if(![rootPath hasSuffix:@"/"])
    {
        rootPath = [rootPath stringByAppendingString:@"/"];
    }
    NSString *canditateSlash = [candidatePath hasSuffix:@"/"] ? candidatePath : [candidatePath stringByAppendingString:@"/"];
    return [canditateSlash isEqualToString:rootPath] || [canditateSlash hasPrefix:rootPath];
}

@interface NXBootstrap ()

@property (readwrite) UInt64 version;

@end

@implementation NXBootstrap {
    NSURL *_rootURL;
    dispatch_once_t _gatherRootURLOnce;
}

- (instancetype)init
{
    self = [super init];
    return self;
}

+ (instancetype)shared
{
    static NXBootstrap *bootstrapSingleton = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bootstrapSingleton = [[NXBootstrap alloc] init];
    });
    return bootstrapSingleton;
}

- (NSURL*)rootURL
{
    dispatch_once(&_gatherRootURLOnce, ^{
        _rootURL = [NSURL fileURLWithPath:[[@"/private" stringByAppendingPathComponent:NSHomeDirectory()] stringByAppendingPathComponent:@"Documents"]];
    });
    return _rootURL;
}

- (NSURL*)sdkURL
{
    return [self.rootURL URLByAppendingPathComponent:[@"SDK/" stringByAppendingString:NXBOOTSTRAP_SDK_NAME]];
}

- (NSURL*)pluginsURL
{
    return [self.rootURL URLByAppendingPathComponent:NXBOOTSTRAP_PLUGINS_DIRNAME];
}

- (NSURL*)includeURL
{
    return [self.rootURL URLByAppendingPathComponent:@"Include"];
}

- (NSURL*)projectsURL
{
    return [self.rootURL URLByAppendingPathComponent:@"Projects"];
}

- (NSURL*)cacheURL
{
    return [self.rootURL URLByAppendingPathComponent:@"Cache"];
}

- (NSURL*)bootstrapPlistURL
{
    return [self.rootURL URLByAppendingPathComponent:@"bootstrap.plist"];
}

- (NSURL*)swiftURL
{
    return [self.rootURL URLByAppendingPathComponent:@"swift"];
}

- (NSURL*)swiftModuleCacheURL
{
    return [self.rootURL URLByAppendingPathComponent:@"ModuleCache"];
}

/*
 * installs the one SDK and leaves nothing else in SDK/.
 * idempotent: a real, complete NXBOOTSTRAP_SDK_NAME already in
 * place is kept (no download); every other entry in SDK/ (an
 * older SDK, a symlink carrying an older name) is removed. the
 * swift module cache is cleared whenever SDK/ changed under it.
 */
- (BOOL)installSDKWithError:(NSError**)error
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *sdkRootURL = [self.rootURL URLByAppendingPathComponent:@"SDK"];
    NSURL *settingsURL = [self.sdkURL URLByAppendingPathComponent:@"SDKSettings.json"];
    NSDictionary *attributes = [fm attributesOfItemAtPath:self.sdkURL.path error:nil];
    BOOL present = attributes != nil
                && ![attributes[NSFileType] isEqualToString:NSFileTypeSymbolicLink]
                && [fm fileExistsAtPath:settingsURL.path];
    BOOL changed = NO;
    
    [fm createDirectoryAtURL:sdkRootURL withIntermediateDirectories:YES attributes:nil error:nil];
    
    if(!present)
    {
        /*
         * not installed yet: nothing to fetch, nothing to extract. the
         * owner copies the SDK folder in; the builder refuses to build
         * until then. not a bootstrap error (that would wipe Documents).
         */
        NSLog(@"no SDK installed at %@ (copy %@ into Documents/SDK)", self.sdkURL.path, NXBOOTSTRAP_SDK_NAME);
    }
    
    /*
     * nothing but the one SDK lives in SDK/.
     */
    NSArray<NSURL*> *entries = [fm contentsOfDirectoryAtURL:sdkRootURL includingPropertiesForKeys:nil options:0 error:nil];
    for(NSURL *entry in entries)
    {
        if([entry.lastPathComponent isEqualToString:NXBOOTSTRAP_SDK_NAME])
        {
            continue;
        }
        
        NSLog(@"removing %@ from SDK/", entry.lastPathComponent);
        if(![fm removeItemAtURL:entry error:error])
        {
            return NO;
        }
        
        changed = YES;
    }
    
    if(changed)
    {
        [fm removeItemAtURL:self.swiftModuleCacheURL error:nil];    /* clearing module cache */
    }
    
    if(!present)
    {
        return YES;
    }
    
    /*
     * the SDK must be readable and must be the one SDK. anything
     * else is a failure of the bootstrap, never a fallback.
     */
    MDKSDK *sdk = [MDKSDK sdkForDirectoryURL:self.sdkURL];
    if(sdk == nil || sdk.supportedVersions.count == 0 || sdk.version.versionString == nil)
    {
        if(error) *error = [NSError errorWithDomain:@"" code:0 userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ is unreadable (no SDKSettings / no deployment targets)", NXBOOTSTRAP_SDK_NAME] }];
        return NO;
    }
    
    if(![sdk.version.versionString isEqualToString:NXBOOTSTRAP_SDK_OSVERSION])
    {
        if(error) *error = [NSError errorWithDomain:@"" code:0 userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ reports version %@, expected %@", NXBOOTSTRAP_SDK_NAME, sdk.version.versionString, NXBOOTSTRAP_SDK_OSVERSION] }];
        return NO;
    }
    
    return YES;
}

/*
 * mechanical format check only (Mach-O magic, any slice) -- this does NOT
 * dlopen the file (bootstrap is not the place to execute an untrusted/
 * mis-copied binary) and does NOT check architecture, platform (macOS vs
 * iOS) or code signature: none of that is knowable without actually
 * trying to load it, which NXPhaseEngine's own -load-plugin-library does
 * at real build time and reports through the normal Swift diagnostic
 * path. This only keeps obvious junk (a partial rsync, an .html Apple
 * error page, a renamed non-dylib) out of plugins/.
 */
static BOOL NXIsLikelyMachODylibAtPath(NSString *path)
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if(handle == nil)
    {
        return NO;
    }
    NSData *header = [handle readDataOfLength:4];
    [handle closeFile];
    if(header.length != 4)
    {
        return NO;
    }

    UInt32 magic = 0;
    [header getBytes:&magic length:4];

    switch(magic)
    {
        case 0xfeedfacfU: /* MH_MAGIC_64, little-endian host */
        case 0xcffaedfeU: /* MH_CIGAM_64 */
        case 0xfeedfaceU: /* MH_MAGIC (32-bit) */
        case 0xcefaedfeU: /* MH_CIGAM */
        case 0xcafebabeU: /* FAT_MAGIC (universal) */
        case 0xbebafecaU: /* FAT_CIGAM */
            return YES;
        default:
            return NO;
    }
}

/*
 * plugins/ is OPTIONAL and owner-installed (see NXBOOTSTRAP_PLUGINS_DIRNAME
 * in the header). unlike installSDKWithError:, an absent or empty
 * directory here is never a failure -- it only means NXPhaseEngine finds
 * nothing to pass to -load-plugin-library and any macro needing one of
 * these plugins fails to resolve, loudly, at that point. this step's own
 * job is narrower: keep plugins/ free of anything that isn't structurally
 * a Mach-O dylib, so a bad copy can't silently sit there looking installed.
 */
- (BOOL)verifyPluginsWithError:(NSError**)error
{
    NSFileManager *fm = [NSFileManager defaultManager];

    [fm createDirectoryAtURL:self.pluginsURL withIntermediateDirectories:YES attributes:nil error:nil];

    NSArray<NSURL*> *entries = [fm contentsOfDirectoryAtURL:self.pluginsURL includingPropertiesForKeys:nil options:0 error:nil];
    if(entries == nil || entries.count == 0)
    {
        NSLog(@"no plugins installed at %@ (macros needing an installed plugin will fail to resolve until plugin dylibs are copied in -- see z97's push-plugins)", self.pluginsURL.path);
        return YES;
    }

    for(NSURL *entry in entries)
    {
        BOOL isDirectory = NO;
        [fm fileExistsAtPath:entry.path isDirectory:&isDirectory];
        BOOL looksRight = !isDirectory
                        && [entry.lastPathComponent.pathExtension isEqualToString:@"dylib"]
                        && NXIsLikelyMachODylibAtPath(entry.path);
        if(!looksRight)
        {
            NSLog(@"pruning %@ from plugins/ (not a .dylib / not Mach-O)", entry.lastPathComponent);
            [fm removeItemAtURL:entry error:nil];
        }
    }

    return YES;
}

- (NSURL*)rootfsURL
{
    NSURL *rootfsURL = [self.rootURL URLByAppendingPathComponent:@"rootfs"];
    [[NSFileManager defaultManager] createDirectoryAtURL:rootfsURL withIntermediateDirectories:NO attributes:nil error:nil];
    return rootfsURL;
}

- (UInt64)version
{
    NSDictionary *bootstrapPlist = [NSDictionary dictionaryWithContentsOfURL:self.bootstrapPlistURL];
    if(bootstrapPlist == nil)
    {
        /* plist doesn't exist or is malformed? */
        return 0;
    }
    
    NSNumber *versionNumber = bootstrapPlist[@"BootstrapVersion"];
    if(![versionNumber isKindOfClass:NSNumber.class])
    {
        /* illegal object */
        return 0;
    }
    
    return [versionNumber unsignedLongValue];
}

- (void)setVersion:(UInt64)version
{
    [XCButton updateProgressWithValue:NXBOOTSTRAP_CSTEP * version];
    [@{ @"BootstrapVersion":[NSNumber numberWithUnsignedLong:version] } writeToURL:self.bootstrapPlistURL error:nil];
}

- (BOOL)isInstalled
{
    return self.version > 0;
}

- (void)bootstrap
{
    NSLog(@"checking upon nyxian bootstrap :3");
    
    MDKPthreadDispatch(^{
        NSError *error = nil;
        
        goto skip_error_report;
        
    report_error:
        {
            NSLog(@"bootstrapping sadly failed :c");
            [NotificationServer NotifyUserWithLevel:NotifLevelError notification:[NSString stringWithFormat:@"Bootstrapping failed: %@", error.localizedDescription] delay:1.0];
            self.version = 0;
            [self clearURL:self.rootURL];
            return;
        }
        
    skip_error_report:
        
        /*
         * checking weither we have to create the
         * bootstraps root path.
         */
        if(![[NSFileManager defaultManager] fileExistsAtPath:self.rootURL.path])
        {
            [[NSFileManager defaultManager] createDirectoryAtURL:self.rootURL withIntermediateDirectories:YES attributes:nil error:&error];
            if(error != nil)
            {
                abort();
            }
        }
        
        NSLog(@"install status: %d", self.isInstalled);
        NSLog(@"version: %llu", self.version);
        
        if(!self.isInstalled || self.version != NXBOOTSTRAP_NEWEST_VERSION)
        {
            /*
             * need to clear the entire path if its not installed
             * otherwise garbage might be in the container.
             * we also have to clear it in case a newer version
             * of the bootstrap is installed.
             */
            if(!self.isInstalled || self.version > NXBOOTSTRAP_NEWEST_VERSION)
            {
                NSLog(@"bootstrap might be too new or not installed, clearing");
                [self clearURL:self.rootURL];
            }
            
            /*
             * now installing or upgrading the bootstrap, this is the part
             * that has to work although nobody is going to use Nyxian today
             * lol.
             */
            if(self.version < 9)
            {
                /*
                 * creating bootstrap base structure
                 * all base folders n such, you name it.
                 */
                NSLog(@"bootstrapping directory structure");
                
                [[NSFileManager defaultManager] createDirectoryAtURL:self.projectsURL withIntermediateDirectories:NO attributes:nil error:&error];
                
                if(![[NSFileManager defaultManager] createDirectoryAtURL:self.cacheURL withIntermediateDirectories:NO attributes:nil error:&error])
                {
                    goto report_error;
                }
                
                self.version = 9;
            }
            
            if(self.version < 10)
            {
                /*
                 * this step is for the rt static library
                 * which is needed for availability checks
                 * using @available in objc for example.
                 */
                NSLog(@"bootstrapping libraries");
                [[NSFileManager defaultManager] removeItemAtURL:[self.rootURL URLByAppendingPathComponent:@"lib"] error:nil];
                
                if(!unzipArchiveAtPath([NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Shared/lib.zip"].path, self.rootURL.path))
                {
                    error = [NSError errorWithDomain:@"" code:0 userInfo:@{ NSLocalizedDescriptionKey: @"extracting \"lib.zip\" failed" }];
                    goto report_error;
                }
                
                self.version = 10;
            }
            
            if(self.version < 15)
            {
                /*
                 * there was a DOS vulnerability in a prior
                 * version of Nyxian where a zip could of caused
                 * DOS in project import functionality. so we
                 * have to fixup paths in case they were affected.
                 * as patching the DOS entry it self does not
                 * prevent it to still cause DOS as damage
                 * might already happened.
                 */
                NSURL *tmpUrl = [NSURL fileURLWithPath:NSTemporaryDirectory()];
                NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtURL:tmpUrl includingPropertiesForKeys:nil options:0 errorHandler:nil];
                if(enumerator == nil)
                {
                    error = [NSError errorWithDomain:@"" code:0 userInfo:@{ NSLocalizedDescriptionKey: @"failed to create enumerator" }];
                    goto report_error;
                }
                
                if(![[NSFileManager defaultManager] setAttributes:@{ NSFilePosixPermissions: @(0755) } ofItemAtPath:tmpUrl.path error:&error])
                {
                    goto report_error;
                }
                
                for(NSURL *fileURL in enumerator)
                {
                    BOOL isDirectory = NO;
                    if(![[NSFileManager defaultManager] fileExistsAtPath:fileURL.path isDirectory:&isDirectory])
                    {
                        continue;
                    }
                    
                    if(![[NSFileManager defaultManager] setAttributes:@{ NSFilePosixPermissions: isDirectory ? @(0755) : @(0644)} ofItemAtPath:fileURL.path error:&error])
                    {
                        goto report_error;
                    }
                }
                
                self.version = 15;
            }
            
            if(self.version < 23)
            {
                /*
                 * this is necessary so simd and normal
                 * c code work perfectly.
                 */
                NSLog(@"bootstrapping clang include and swift resources");
                [[NSFileManager defaultManager] removeItemAtURL:self.includeURL error:nil];
                [[NSFileManager defaultManager] removeItemAtURL:self.swiftURL error:nil];
                
                if(!unzipArchiveAtPath([NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Shared/include.zip"].path, [self.rootURL URLByAppendingPathComponent:@"Include"].path))
                {
                    error = [NSError errorWithDomain:@"" code:0 userInfo:@{ NSLocalizedDescriptionKey: @"extracting \"include.zip\" failed" }];
                    goto report_error;
                }
                
                /*
                 * this is necessary so swift works
                 */
                if(!unzipArchiveAtPath([NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Shared/swift.zip"].path, self.rootURL.path))
                {
                    error = [NSError errorWithDomain:@"" code:0 userInfo:@{ NSLocalizedDescriptionKey: @"extracting \"swift.zip\" failed" }];
                    goto report_error;
                }
                
                self.version = 23;
            }
            
            if(self.version < 27)
            {
                /*
                 * the SDK is very important to use iOS API which
                 * is very cool.
                 */
                if(![self installSDKWithError:&error])
                {
                    goto report_error;
                }
                
                self.version = 27;
            }
            
            if(self.version < 28)
            {
                NSLog(@"bootstrapping rootca folder");
                
                [[NSFileManager defaultManager] createDirectoryAtURL:[self.rootURL URLByAppendingPathComponent:@"RootCAs"] withIntermediateDirectories:true attributes:nil error:nil];
                
                if(!fdownload(@"https://nyxian.app/bootstrap/org.emexlabs.rootca.v1.pub.nxt2c", @"org.emexlabs.rootca.v1.pub.nxt2c"))
                {
                    error = [NSError errorWithDomain:@"" code:0 userInfo:@{ NSLocalizedDescriptionKey: @"downloading \"https://nyxian.app/bootstrap/org.emexlabs.rootca.v1.pub.nxt2c\" failed" }];
                    goto report_error;
                }
                
                if(![[NSFileManager defaultManager] moveItemAtPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"org.emexlabs.rootca.v1.pub.nxt2c"] toPath:[[self.rootURL URLByAppendingPathComponent:@"RootCAs/org.emexlabs.rootca.v1.pub.nxt2c"] path] error:nil])
                {
                    error = [NSError errorWithDomain:@"" code:0 userInfo:@{ NSLocalizedDescriptionKey: @"failed to move emexlabs public rootca key" }];
                    goto report_error;
                }
                
                ksurface_keychain_update();
                
                self.version = 28;
            }
            if(self.version < 29)
            {
                /*
                 * the default SDK became iPhoneOS27.0.sdk here.
                 */
                if(![self installSDKWithError:&error])
                {
                    goto report_error;
                }
                
                self.version = 29;
            }
            
            if(self.version < 30)
            {
                /*
                 * the one SDK, and only it: removes the symlinks v29
                 * left behind carrying older SDK names, re-checks the
                 * SDK, and clears the module cache if anything moved.
                 */
                if(![self installSDKWithError:&error])
                {
                    goto report_error;
                }
                
                self.version = 30;
            }
            
            if(self.version < 31)
            {
                /*
                 * the SDK is installed locally by the owner (copied into
                 * Documents/SDK); this step only verifies and prunes.
                 */
                if(![self installSDKWithError:&error])
                {
                    goto report_error;
                }
                
                self.version = 31;
            }

            if(self.version < 32)
            {
                /*
                 * plugins/ for Apple's own macro-plugin dylibs (owner-
                 * installed, same model as SDK/). missing/empty is not a
                 * bootstrap error; this only prunes non-dylib junk.
                 */
                if(![self verifyPluginsWithError:&error])
                {
                    goto report_error;
                }

                self.version = 32;
            }
        }

        NSLog(@"done");
    });
}

- (NSString*)relativeToBootstrapWithAbsolutePath:(NSString*)path
{
    NSURL *absolutURL = [NSURL fileURLWithPath:path];
    if(![absolutURL.path hasPrefix:[self.rootURL.path stringByAppendingString:@"/"]] &&
       ![absolutURL.path isEqualToString:self.rootURL.path])
    {
        return nil;
    }
    return [absolutURL.path stringByReplacingOccurrencesOfString:[self.rootURL.path stringByAppendingString:@"/"] withString:@""];
}

- (void)clearURL:(NSURL*)url
{
    NSArray<NSURL*> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:url includingPropertiesForKeys:nil options:0 error:nil];
    if(entries == nil)
    {
        return;
    }
    
    for(NSURL *entry in entries)
    {
        if(!(url == self.rootURL && ([entry.lastPathComponent isEqualToString:@"Projects"] ||
                                     [entry.lastPathComponent isEqualToString:@"rootfs"] ||
                                     [entry.lastPathComponent isEqualToString:@"mntfs"] ||
                                     [entry.lastPathComponent isEqualToString:@"kmsg.txt"] ||
                                     [entry.lastPathComponent isEqualToString:@"kmsg_old.txt"])))
        {
            [[NSFileManager defaultManager] removeItemAtURL:entry error:nil];
        }
    }
}

- (void)waitTillDone
{
    if(self.version == NXBOOTSTRAP_NEWEST_VERSION)
    {
        return;
    }
    
    [XCButton switchImageWithSystemName:@"archivebox.fill" animated:YES];
    [XCButton updateProgressWithValue:0.1];
    
    while(self.version != NXBOOTSTRAP_NEWEST_VERSION)
    {
        relax();
    }
    
    [XCButton switchImageWithSystemName:@"hammer.fill" animated:YES];
}

- (void)waitTillDoneNoButton
{
    if(self.version == NXBOOTSTRAP_NEWEST_VERSION)
    {
        return;
    }
    
    [XCButton switchImageWithSystemName:@"archivebox.fill" animated:YES];
    [XCButton updateProgressWithValue:0.1];
    
    while(self.version != NXBOOTSTRAP_NEWEST_VERSION)
    {
        relax();
    }
    
    [XCButton switchImageWithSystemName:@"hammer.fill" animated:YES];
}

- (BOOL)isNewest
{
    return self.version == NXBOOTSTRAP_NEWEST_VERSION;
}

@end
