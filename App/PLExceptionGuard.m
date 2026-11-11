#import "PLExceptionGuard.h"

BOOL PLTryCatch(void (^block)(void)) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[PixelLift] caught ObjC exception: %@ — %@", exception.name, exception.reason);
        return NO;
    }
}
