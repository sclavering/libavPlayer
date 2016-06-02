#import "LAVPMovie.h"
#import "lavp_common.h"

@interface LAVPMovie (Internal)
-(NSSize) sizeForGLTextures;
-(AVFrame*) getCurrentFrame;
@end
