#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include "OmniRotation.h"
@interface NSObject (OmniPanelSignatures)
- (instancetype)initWithCGSDisplayID:(int)display;
- (BOOL)canChangeOrientation;
- (void)setOrientation:(int)degrees;
@end
// Signature statically reviewed against displayplacer (MIT), MPDisplay.h.
// No upstream executable is linked. The local macOS 27 MPDisplay setter was
// inspected read-only: it calls SLSSetDisplayRotation(displayID, int degrees),
// then discards its CGError because the Objective-C setter returns void.
// Capture that same function's status; status zero is NOT observed completion.
typedef int (*SetRotationFunction)(uint32_t, int);
static SetRotationFunction rotationFunction(void) {
    static void *sky;
    static SetRotationFunction function;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (sky) function = (SetRotationFunction)dlsym(sky, "SLSSetDisplayRotation");
    });
    return function;
}
static Class displayClass(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ handle = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY); });
    return handle ? NSClassFromString(@"MPDisplay") : Nil;
}
bool ODRotationAvailable(void) {
    Class cls = displayClass();
    return cls && rotationFunction() && [cls instancesRespondToSelector:sel_registerName("initWithCGSDisplayID:")] && [cls instancesRespondToSelector:sel_registerName("setOrientation:")];
}
int ODRotateDisplay(uint32_t display, int degrees) {
    if (!(degrees == 0 || degrees == 90 || degrees == 180 || degrees == 270) || !ODRotationAvailable()) return 1;
    @try {
        id panel = [[displayClass() alloc] initWithCGSDisplayID:(int)display];
        if (!panel) return 2;
        SEL can = sel_registerName("canChangeOrientation");
        if (![panel respondsToSelector:can] || ![panel canChangeOrientation]) {  return 3; }
        // No fallback to the void setter: it would silently discard rejection.
        return rotationFunction()(display, degrees);
    } @catch (NSException *exception) { return 4; }
}
