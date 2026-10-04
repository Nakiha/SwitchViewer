#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

void SVInstallWriterTracking(Class bufferClass);
void SVTrackSourceDrawable(id<CAMetalDrawable> drawable);
BOOL SVPrepareDirectAfterGPU(id<CAMetalDrawable> drawable, CAMetalLayer *layer, double requestedAt);
