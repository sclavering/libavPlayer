#import "LAVPMovie.h"
#import "MovieState.h"

typedef struct IntSize_ { int width, height; } IntSize;

@interface LAVPMovie (Internal)
-(IntSize) sizeForGLTextures;
-(void) ifNewVideoFrameIsAvailableThenRun:(void (^)(AVFrame *))func;
@end
