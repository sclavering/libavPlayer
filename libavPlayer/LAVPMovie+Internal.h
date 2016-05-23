#import "LAVPMovie.h"
#import "lavp_common.h"

@interface LAVPMovie (Internal)
- (NSSize) sizeForGLTextures;
- (Frame*) getCurrentFrame;
- (void) haveReachedEOF;
- (void) haveFinishedSeekingWhilePaused;
@end
