#import "LAVPMovie.h"
#import "lavp_common.h"

@interface LAVPMovie (Internal)
- (Frame*) getCurrentFrame;
- (void) haveReachedEOF;
@end
