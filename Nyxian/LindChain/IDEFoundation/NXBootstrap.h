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

#ifndef NXBOOTSTRAP_H
#define NXBOOTSTRAP_H

#import <Foundation/Foundation.h>

#define NXBOOTSTRAP_NEWEST_VERSION  31
#define NXBOOTSTRAP_CSTEP           (double)(1.0 / NXBOOTSTRAP_NEWEST_VERSION)

/*
 * the one and only SDK. every path, flag and fallback that
 * names an SDK version derives from these; nothing else
 * names one. (MobileDevelopmentKit is a separate framework
 * and repeats the version string in its own fallback.)
 */
#define NXBOOTSTRAP_SDK_OSVERSION   @"27.0"
#define NXBOOTSTRAP_SDK_NAME        @"iPhoneOS27.0.sdk"
/*
 * the SDK ships INSIDE this app (Shared/sdk/, a folder reference, filled
 * by CI from the fork's "sdk" release asset). sdk.build holds the SDK's
 * ProductBuildVersion; the bootstrap replaces the installed SDK whenever
 * it differs. nothing is downloaded from nyxian.app for the SDK.
 */
#define NXBOOTSTRAP_SDK_ZIP         @"Shared/sdk/iPhoneOS27.0.sdk.zip"
#define NXBOOTSTRAP_SDK_BUILD_FILE  @"Shared/sdk/sdk.build"

@interface NXBootstrap : NSObject

@property (nonatomic, readonly, strong, nonnull) NSURL *rootURL;
@property (nonatomic, readonly, strong, nonnull) NSURL *sdkURL;
@property (nonatomic, readonly, strong, nonnull) NSURL *includeURL;
@property (nonatomic, readonly, strong, nonnull) NSURL *projectsURL;
@property (nonatomic, readonly, strong, nonnull) NSURL *cacheURL;
@property (nonatomic, readonly, strong, nonnull) NSURL *bootstrapPlistURL;
@property (nonatomic, readonly, strong, nonnull) NSURL *swiftURL;
@property (nonatomic, readonly, strong, nonnull) NSURL *swiftModuleCacheURL;
@property (nonatomic, readonly, strong, nonnull) NSURL *rootfsURL;

@property (atomic, readonly) UInt64 version;
@property (atomic, readonly) BOOL isInstalled;

- (instancetype _Nonnull)init;
+ (instancetype _Nonnull)shared;

- (void)bootstrap;

- (NSString  * _Nullable)relativeToBootstrapWithAbsolutePath:( NSString  * _Nonnull)path;
- (void)clearURL:(NSURL * _Nonnull)url;

- (void)waitTillDone;
- (void)waitTillDoneNoButton;
- (BOOL)isNewest;

@end

#endif /* NXBOOTSTRAP_H */
