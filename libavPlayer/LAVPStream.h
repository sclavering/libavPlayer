//
//  LAVPStream.h
//  libavPlayer
//
//  Created by Takashi Mochizuki on 11/06/18.
//  Copyright 2011 MyCometG3. All rights reserved.
//
/*
 This file is part of livavPlayer.

 livavPlayer is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.

 livavPlayer is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with libavPlayer; if not, write to the Free Software
 Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#import <Cocoa/Cocoa.h>
#import <QTKit/QTTime.h>

@class LAVPDecoder;
@protocol LAVPStreamOutput;

@interface LAVPStream : NSObject {
    NSURL    *url;
@private
    LAVPDecoder *decoder;
    uint64_t _htOffset;     // CVHostTime offset when play
    double_t _posOffset;    // movie time in {0.0, 1.0}
    NSTimer *timer;         // notification timer when EndOfMovie reached
    Float32 currentVol;
    BOOL _busy;
}

// In practice this is an LAVPLayer.  The stream needs to be able to tell it to start/stop updating when paused/unpaused (so the layer doesn't waste tons of CPU), and also to explicitly update if seeking while paused.
@property (weak) id<LAVPStreamOutput> streamOutput;

@property (retain, readonly) NSURL *url;

@property (readonly) NSSize frameSize;
@property (readonly) QTTime duration;
@property (assign) QTTime currentTime;
@property (assign) double_t position;

// Note: set this to 0 to pause/stop, and to 1.0 to start playing at normal speed.  Read it to determine whether the stream is currently being played.
@property (assign) double_t rate;

@property (assign) Float32 volume;
@property (readonly) BOOL busy;

- (id) initWithURL:(NSURL *)url error:(NSError **)errorPtr;
+ (id) streamWithURL:(NSURL *)url error:(NSError **)errorPtr;

- (BOOL) readyForCurrent;
- (BOOL) readyForTime:(const CVTimeStamp*)ts;
- (CVPixelBufferRef) getCVPixelBuffer;

@end



@protocol LAVPStreamOutput

// Called e.g. after seeking while paused.
-(void) streamOutputNeedsSingleUpdate;
// Called when playback starts or stops for any reason.
-(void) streamOutputNeedsContinuousUpdating:(bool)continuousUpdating;

@end;
