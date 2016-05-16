//
//  LAVPDecoder.h
//  libavPlayer
//
//  Created by Takashi Mochizuki on 11/06/18.
//  Copyright 2011 MyCometG3. All rights reserved.
//
/*
 This file is part of libavPlayer.

 libavPlayer is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.

 libavPlayer is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with libavPlayer; if not, write to the Free Software
 Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#import <Cocoa/Cocoa.h>

#include "lavp_common.h"
#import "LAVPMovie.h"

@class VideoState;

@interface LAVPDecoder : NSObject {
@private
    VideoState *is;
    CVPixelBufferRef pb;
    double lastPosition;
}

@property (weak) LAVPMovie* owningStream;

- (id) initWithURL:(NSURL *)sourceURL error:(NSError **)errorPtr;
- (void) threadMain;

- (CVPixelBufferRef) getPixelBuffer;
- (NSSize) frameSize;

- (CGFloat) rate;
- (void) setRate:(CGFloat)rate;
- (int64_t) duration;
- (int64_t) position;
- (void) setPosition:(int64_t)pos blocking:(BOOL)blocking;
- (float) volume;
- (void) setVolume:(float)volume;

- (void) haveReachedEOF;
@end
