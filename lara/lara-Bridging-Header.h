//
//  lara-Bridging-Header.h
//  lara
//

@import UIKit;
#import <Foundation/Foundation.h>
#import "overlay/CoreSetHUDHost.h"
#import "overlay/CoreSetImGuiMenuSurface.h"

#import "darksword.h"
#import "offsets.h"
#import "utils.h"
#import "headers/AXLauncherAuthorizationPolicy.h"
#import "vnode.h"
#import "apfs.h"
#import "vfs.h"
#import "sbx.h"
#import "IconServices.h"
#import "rc.h"
#import "RemoteCall.h"
#import "overlay/CoreSetReadSession.h"
#import "overlay/CoreSetTargetWriteSession.h"
#import "overlay/CoreSetIsolatedWriteProbe.h"
#import "overlay/CoreSetKernelWriteProfile.h"
#import "overlay/CoreSetPlayerSnapshot.h"
#import "overlay/CoreSetMaterialSnapshot.h"
#import "overlay/CoreSetPerformanceSampler.h"
#import "overlay/CoreSetMetalRenderAdapter.h"
#import "overlay/CoreSetRemoteHostingAdapter.h"
#import "overlay/CoreSetFloatingSceneManager.h"
#import "decrypt.h"
#import "persistence.h"
#import "ota.h"
#import "screentime.h"

#import <zlib.h>

long findcachedataoff(const char *mgkey);
void LaraClearIconCache(void);

@interface UIDevice(Private)
+ (BOOL)_hasHomeButton;
@end

void test(NSString *path);

NS_ASSUME_NONNULL_BEGIN

@interface VarCleanBridge : NSObject

+ (NSDictionary *)loadRulesNamed:(NSString *)resourceName
                        inBundle:(NSBundle *)bundle
                           error:(NSError * _Nullable * _Nullable)error;

+ (BOOL)probePathExists:(NSString *)path
            isDirectory:(BOOL *)isDirectory
              isSymlink:(BOOL *)isSymlink;

@end

NS_ASSUME_NONNULL_END
