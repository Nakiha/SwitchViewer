#import "DrawableWriterTracking.h"
#import <objc/runtime.h>

extern uint64_t SVGameHookPrepare(void *, void *, void *, double, double, double, double);
extern void SVGameHookNativePresented(uint64_t, double, double, double);
extern void SVGameHookCaptureFallback(double, const char *);

static char contextKey, blitBufferKey, captureQueueKey;
static NSMutableSet *bufferClasses, *blitClasses;

@interface SVWeakBuffer : NSObject
@property(nonatomic, weak) id<MTLCommandBuffer> buffer;
@end
@implementation SVWeakBuffer
@end

@interface SVWriterTicket : NSObject
@property(nonatomic, weak) id<MTLCommandBuffer> buffer;
@property(nonatomic) BOOL completed;
@property(nonatomic) BOOL failed;
@property(nonatomic) double gpuEnd;
@property(nonatomic, copy) NSString *label;
@property(nonatomic, strong) dispatch_group_t completion;
@end
@implementation SVWriterTicket
@end

@interface SVDrawableWriters : NSObject
@property(nonatomic, strong) NSMutableArray<SVWriterTicket *> *tickets;
@property(nonatomic) BOOL overflow;
@end
@implementation SVDrawableWriters
- (instancetype)init {
    if ((self = [super init])) _tickets = [NSMutableArray array];
    return self;
}
@end

// Delivery can race GPU completion and presentation. Publish exactly once only
// after the Swift capture ID and the original presentation callback both exist.
@interface SVNativeDelivery : NSObject
@property(nonatomic) uint64_t captureID;
@property(nonatomic) BOOL captured;
@property(nonatomic) BOOL presented;
@property(nonatomic) BOOL delivered;
@property(nonatomic) double requestedAt;
@property(nonatomic) double presentedAt;
@property(nonatomic) double callbackAt;
- (void)publish;
@end
@implementation SVNativeDelivery
- (void)publish {
    @synchronized(self) {
        if (!_captured || !_presented || _delivered) return;
        _delivered = YES;
        if (_captureID) SVGameHookNativePresented(_captureID, _requestedAt, _presentedAt, _callbackAt);
    }
}
@end

void SVTrackSourceDrawable(id<CAMetalDrawable> drawable) {
    // A pooled drawable/texture gets a fresh context each time nextDrawable
    // hands it out. Previous callbacks retain their own context, never this one.
    objc_setAssociatedObject(drawable.texture, &contextKey, [SVDrawableWriters new], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void trackWriter(id<MTLCommandBuffer> buffer, id<MTLTexture> texture) {
    SVDrawableWriters *context = objc_getAssociatedObject(texture, &contextKey);
    while (!context && texture.parentTexture) {
        texture = texture.parentTexture;
        context = objc_getAssociatedObject(texture, &contextKey);
    }
    if (!context || !buffer) return; // Interpolation/private textures have no context.
    @synchronized(context) {
        for (SVWriterTicket *ticket in context.tickets) if (ticket.buffer == buffer) return;
        if (context.tickets.count >= 8) { context.overflow = YES; return; }
        SVWriterTicket *ticket = [SVWriterTicket new];
        ticket.buffer = buffer;
        ticket.label = buffer.label;
        ticket.completion = dispatch_group_create();
        dispatch_group_enter(ticket.completion);
        [context.tickets addObject:ticket];
        [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            @synchronized(context) {
                ticket.failed = completed.status != MTLCommandBufferStatusCompleted || completed.GPUEndTime <= 0;
                ticket.gpuEnd = completed.GPUEndTime;
                ticket.completed = YES;
            }
            dispatch_group_leave(ticket.completion);
        }];
    }
}

static void trackPass(id<MTLCommandBuffer> buffer, MTLRenderPassDescriptor *pass) {
    for (NSUInteger index = 0; index < 8; index++) {
        trackWriter(buffer, pass.colorAttachments[index].texture);
        trackWriter(buffer, pass.colorAttachments[index].resolveTexture);
    }
}

static void hookBlit(Class cls) {
    @synchronized(blitClasses) {
        if ([blitClasses containsObject:cls]) return;
        [blitClasses addObject:cls];
        SEL selector = @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:);
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) return;
        IMP original = method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^(id encoder, id<MTLTexture> source, NSUInteger sourceSlice,
            NSUInteger sourceLevel, MTLOrigin sourceOrigin, MTLSize size, id<MTLTexture> destination,
            NSUInteger destinationSlice, NSUInteger destinationLevel, MTLOrigin destinationOrigin) {
            trackWriter(((SVWeakBuffer *)objc_getAssociatedObject(encoder, &blitBufferKey)).buffer, destination);
            ((void (*)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin))original)
                (encoder, selector, source, sourceSlice, sourceLevel, sourceOrigin, size, destination,
                 destinationSlice, destinationLevel, destinationOrigin);
        });
        class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    }
}

void SVInstallWriterTracking(Class cls) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ bufferClasses = [NSMutableSet set]; blitClasses = [NSMutableSet set]; });
    @synchronized(bufferClasses) {
        if ([bufferClasses containsObject:cls]) return;
        [bufferClasses addObject:cls];
        for (NSString *name in @[@"renderCommandEncoderWithDescriptor:", @"parallelRenderCommandEncoderWithDescriptor:"]) {
            SEL selector = NSSelectorFromString(name);
            Method method = class_getInstanceMethod(cls, selector);
            if (!method) continue;
            IMP original = method_getImplementation(method);
            IMP replacement = imp_implementationWithBlock(^id(id buffer, MTLRenderPassDescriptor *pass) {
                id encoder = ((id (*)(id, SEL, id))original)(buffer, selector, pass);
                if (encoder) trackPass(buffer, pass);
                return encoder;
            });
            class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
        }
        SEL selector = @selector(blitCommandEncoder);
        Method method = class_getInstanceMethod(cls, selector);
        if (method) {
            IMP original = method_getImplementation(method);
            IMP replacement = imp_implementationWithBlock(^id(id buffer) {
                id encoder = ((id (*)(id, SEL))original)(buffer, selector);
                if (encoder) {
                    SVWeakBuffer *reference = [SVWeakBuffer new];
                    reference.buffer = buffer;
                    objc_setAssociatedObject(encoder, &blitBufferKey, reference, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    hookBlit(object_getClass(encoder));
                }
                return encoder;
            });
            class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
        }
        // Unreal's wrappers cache encoder IMPs too; install before main().
        id<MTLCommandBuffer> probe = [[MTLCreateSystemDefaultDevice() newCommandQueue] commandBuffer];
        id encoder = [probe blitCommandEncoder];
        if (encoder) { hookBlit(object_getClass(encoder)); [encoder endEncoding]; }
    }
}

static BOOL fallback(double time, const char *reason) {
    SVGameHookCaptureFallback(time, reason);
    return NO;
}

BOOL SVPrepareDirectAfterGPU(id<CAMetalDrawable> drawable, CAMetalLayer *layer, double requestedAt) {
    if (getenv("SWITCHVIEWER_CAPTURE_AFTER_PRESENT")) return fallback(requestedAt, "comparisonBaseline"); // Fixture A/B baseline.
    SVDrawableWriters *context = objc_getAssociatedObject(drawable.texture, &contextKey);
    NSArray<SVWriterTicket *> *tickets;
    @synchronized(context) {
        if (!context || !context.tickets.count) return fallback(requestedAt, "noTrackedWriter");
        if (context.overflow) return fallback(requestedAt, "writerOverflow");
        tickets = [context.tickets copy];
        id<MTLCommandQueue> queue;
        for (SVWriterTicket *ticket in tickets) {
            id<MTLCommandBuffer> buffer = ticket.buffer;
            if (ticket.failed) return fallback(requestedAt, "writerGPUFailed");
            if (!ticket.completed && (!buffer || buffer.status < MTLCommandBufferStatusCommitted)) return fallback(requestedAt, "writerNotCommitted");
            // Multi-queue writers require stronger dependency tracking; keep the
            // presented-callback fallback instead of guessing the final writer.
            if (buffer) {
                if (queue && queue != buffer.commandQueue) return fallback(requestedAt, "multipleWriterQueues");
                queue = buffer.commandQueue;
            }
        }
    }
    SVNativeDelivery *delivery = [SVNativeDelivery new];
    delivery.requestedAt = requestedAt;
    [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
        @synchronized(delivery) {
            delivery.presented = YES;
            delivery.presentedAt = shown.presentedTime;
            delivery.callbackAt = CACurrentMediaTime();
        }
        [delivery publish];
    }];
    dispatch_group_t all = dispatch_group_create();
    for (SVWriterTicket *ticket in tickets) {
        dispatch_group_enter(all);
        dispatch_group_notify(ticket.completion, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            dispatch_group_leave(all);
        });
    }
    dispatch_group_notify(all, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        double gpuEnd = 0;
        @synchronized(context) {
            for (SVWriterTicket *ticket in tickets) {
                if (ticket.failed) return; // GPU error: leave the game original visible.
                gpuEnd = MAX(gpuEnd, ticket.gpuEnd);
            }
        }
        id<MTLCommandQueue> queue;
        @synchronized(layer) {
            queue = objc_getAssociatedObject(layer, &captureQueueKey);
            if (!queue) {
                queue = [layer.device newCommandQueue];
                objc_setAssociatedObject(layer, &captureQueueKey, queue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        id<MTLCommandBuffer> copy = [queue commandBuffer];
        if (!copy) return;
        copy.label = tickets.lastObject.label;
        uint64_t captureID = SVGameHookPrepare((__bridge void *)copy, (__bridge void *)drawable,
                                             (__bridge void *)layer, requestedAt, -1, 0, gpuEnd);
        @synchronized(delivery) { delivery.captureID = captureID; delivery.captured = YES; }
        [delivery publish];
        [copy commit];
    });
    return YES;
}
