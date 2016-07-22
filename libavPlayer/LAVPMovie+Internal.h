#import "LAVPMovie.h"
#import "MovieState.h"

typedef struct IntSize_ { int width, height; } IntSize;

@interface LAVPMovie (Internal)
-(IntSize) sizeForGLTextures;
-(void) ifNewFrameIsAvailableThenRun:(void (^)(AVFrame *))func;
@end
