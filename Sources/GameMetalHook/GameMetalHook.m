#import "GameMetalHook.h"
#import "DrawableWriterTracking.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>

extern void SVGameHookStart(void);
extern int32_t SVGameHookAcceptsLayer(void *layer);
extern uint64_t SVGameHookPrepare(void *commandBuffer, void *drawable, void *layer,
                              double nativeRequestTime, double nativePresentedTime, double nativeCallbackTime, double nativeGPUTime);
static char layerKey;
static char preparedKey;
static char queueKey;
static char overlaySequenceKey;
static void hookDrawable(Class cls);
extern void SVGameHookOverlayPresent(uint64_t sequence, double time, double requested, int mode);

void SVTagOverlayDrawable(void *pointer, uint64_t sequence) {
    id drawable = (__bridge id)pointer;
    objc_setAssociatedObject(drawable, &overlaySequenceKey, @(sequence), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    hookDrawable(object_getClass(drawable));
}

static void noteOverlayPresent(id drawable, double requested, int mode) {
    NSNumber *sequence = objc_getAssociatedObject(drawable, &overlaySequenceKey);
    if (sequence) SVGameHookOverlayPresent(sequence.unsignedLongLongValue, CACurrentMediaTime(), requested, mode);
}
static NSMutableSet *hookedClasses;
static NSHashTable *hookedDevices;
static NSMutableSet *hookedDrawableClasses;

@interface SVLayerReference : NSObject
@property(nonatomic, weak) CAMetalLayer *layer;
@end
@implementation SVLayerReference
@end

static void prepare(id buffer, id<CAMetalDrawable> drawable) {
    CAMetalLayer *layer = ((SVLayerReference *)objc_getAssociatedObject(drawable, &layerKey)).layer;
    if (layer && ![layer.name isEqualToString:@"SwitchViewer.Interpolation"]) {
        if (objc_getAssociatedObject(drawable, &preparedKey)) return;
        objc_setAssociatedObject(drawable, &preparedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SVGameHookPrepare((__bridge void *)buffer, (__bridge void *)drawable, (__bridge void *)layer, 0, 0, 0, 0);
    }
}

// Unreal can call drawable.present() directly instead of commandBuffer.presentDrawable().
// Wait for its presented callback before copying on our own queue, so the game's GPU
// writes have finished even when its command buffer and our queue are independent.
static void prepareDirect(id<CAMetalDrawable> drawable) {
    CAMetalLayer *layer = ((SVLayerReference *)objc_getAssociatedObject(drawable, &layerKey)).layer;
    if (!layer || objc_getAssociatedObject(drawable, &preparedKey)) return;
    objc_setAssociatedObject(drawable, &preparedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    const double requestedAt = CACurrentMediaTime();
    if (SVPrepareDirectAfterGPU(drawable, layer, requestedAt)) return;
    [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
        const double callbackAt = CACurrentMediaTime();
        id<MTLCommandQueue> queue;
        @synchronized(layer) {
            queue = objc_getAssociatedObject(layer, &queueKey);
            if (!queue) {
                queue = [layer.device newCommandQueue];
                objc_setAssociatedObject(layer, &queueKey, queue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        id<MTLCommandBuffer> buffer = [queue commandBuffer];
        if (!buffer) return;
        SVGameHookPrepare((__bridge void *)buffer, (__bridge void *)presented, (__bridge void *)layer,
                          requestedAt, presented.presentedTime, callbackAt, 0);
        [buffer commit];
    }];
}

static void hookDrawable(Class cls) {
    @synchronized(hookedDrawableClasses) {
        if ([hookedDrawableClasses containsObject:cls]) return;
        [hookedDrawableClasses addObject:cls];
        SEL plain = @selector(present);
        Method method = class_getInstanceMethod(cls, plain);
        if (method) {
            IMP original = method_getImplementation(method);
            class_replaceMethod(cls, plain, imp_implementationWithBlock(^(id drawable) {
                noteOverlayPresent(drawable, 0, 0);
                prepareDirect(drawable);
                ((void (*)(id, SEL))original)(drawable, plain);
            }), method_getTypeEncoding(method));
        }
        for (NSString *name in @[@"presentAtTime:", @"presentAfterMinimumDuration:"]) {
            SEL selector = NSSelectorFromString(name);
            Method timed = class_getInstanceMethod(cls, selector);
            if (!timed) continue;
            IMP original = method_getImplementation(timed);
            class_replaceMethod(cls, selector, imp_implementationWithBlock(^(id drawable, double time) {
                noteOverlayPresent(drawable, time, [name isEqualToString:@"presentAtTime:"] ? 1 : 2);
                prepareDirect(drawable);
                ((void (*)(id, SEL, double))original)(drawable, selector, time);
            }), method_getTypeEncoding(timed));
        }
    }
}

static void hookCommandBuffer(Class cls) {
    @synchronized(hookedClasses) {
        if ([hookedClasses containsObject:cls]) return;
        [hookedClasses addObject:cls];
        SVInstallWriterTracking(cls);
        SEL plain = @selector(presentDrawable:);
        Method method = class_getInstanceMethod(cls, plain);
        if (method) {
            IMP original = method_getImplementation(method);
            IMP replacement = imp_implementationWithBlock(^(id buffer, id<CAMetalDrawable> drawable) {
                prepare(buffer, drawable);
                ((void (*)(id, SEL, id))original)(buffer, plain, drawable);
            });
            class_replaceMethod(cls, plain, replacement, method_getTypeEncoding(method));
        }
        for (NSString *name in @[@"presentDrawable:atTime:", @"presentDrawable:afterMinimumDuration:"]) {
            SEL selector = NSSelectorFromString(name);
            Method timed = class_getInstanceMethod(cls, selector);
            if (!timed) continue;
            IMP original = method_getImplementation(timed);
            IMP replacement = imp_implementationWithBlock(^(id buffer, id<CAMetalDrawable> drawable, double time) {
                prepare(buffer, drawable);
                ((void (*)(id, SEL, id, double))original)(buffer, selector, drawable, time);
            });
            class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(timed));
        }
    }
}

void SVInstallMetalHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hookedClasses = [NSMutableSet set];
        hookedDrawableClasses = [NSMutableSet set];
        hookedDevices = [NSHashTable weakObjectsHashTable];
        // mtlpp (used by Unreal) caches method IMPs when wrapping its first queue.
        // Install before the game's main() constructs those wrappers.
        for (id<MTLDevice> device in MTLCopyAllDevices()) {
            id<MTLCommandQueue> queue = [device newCommandQueue];
            id<MTLCommandBuffer> buffer = [queue commandBuffer];
            if (buffer) hookCommandBuffer(object_getClass(buffer));
            id<MTLCommandBuffer> unretained = [queue commandBufferWithUnretainedReferences];
            if (unretained) hookCommandBuffer(object_getClass(unretained));
        }
        SEL selector = @selector(nextDrawable);
        Method method = class_getInstanceMethod(CAMetalLayer.class, selector);
        IMP original = method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^id(CAMetalLayer *layer) {
            static BOOL loggedLayer = NO;
            if (![layer.name isEqualToString:@"SwitchViewer.Interpolation"] && !loggedLayer) {
                loggedLayer = YES;
                fprintf(stderr, "[SwitchViewerHook] LAYER %.0fx%.0f format=%lu\n", layer.drawableSize.width,
                    layer.drawableSize.height, (unsigned long)layer.pixelFormat);
            }
            BOOL eligible = SVGameHookAcceptsLayer((__bridge void *)layer) != 0;
            if (eligible) {
                layer.framebufferOnly = NO;
                @synchronized(hookedDevices) {
                    if (layer.device && ![hookedDevices containsObject:layer.device]) {
                        id<MTLCommandBuffer> probe = [[layer.device newCommandQueue] commandBuffer];
                        if (probe) {
                            hookCommandBuffer(object_getClass(probe));
                            [hookedDevices addObject:layer.device];
                        }
                    }
                }
            }
            id drawable = ((id (*)(id, SEL))original)(layer, selector);
            if (eligible && drawable) {
                SVLayerReference *reference = [SVLayerReference new];
                reference.layer = layer;
                objc_setAssociatedObject(drawable, &layerKey, reference, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(drawable, &preparedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                SVTrackSourceDrawable(drawable);
                hookDrawable(object_getClass(drawable));
            }
            return drawable;
        });
        method_setImplementation(method, replacement);
    });
}

__attribute__((constructor)) static void startHook(void) {
    if (getenv("SWITCHVIEWER_GAME_HOOK")) {
        SVInstallMetalHooks();
        SVGameHookStart();
    }
}
