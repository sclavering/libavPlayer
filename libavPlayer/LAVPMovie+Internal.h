#import "LAVPMovie.h"
#import "lavp_common.h"

typedef struct IntSize_ { int width, height; } IntSize;

@interface LAVPMovie (Internal)
-(IntSize) sizeForGLTextures;
-(AVFrame*) getCurrentFrame;
@end
