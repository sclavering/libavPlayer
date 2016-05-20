//
//  LAVPMovie.h
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

@class VideoState;
@protocol LAVPMovieOutput;

@interface LAVPMovie : NSObject {
@private
    VideoState *is;
    double lastPosition;
    float currentVol;
}

// In practice this is an LAVPLayer.  The movie needs to be able to tell it to start/stop updating when paused/unpaused (so the layer doesn't waste tons of CPU), and also to explicitly update if seeking while paused.
@property (weak) id<LAVPMovieOutput> movieOutput;

@property (retain, readonly) NSURL *url;

@property (readonly) NSSize frameSize;
@property (readonly) int64_t durationInMicroseconds;
@property (assign) int64_t currentTimeInMicroseconds;
@property (assign) double position;

@property BOOL paused;

// Normally 1.0.  Adjust this to play faster or slower.  Pausing is separate from rate, i.e. if accessed while paused this returns the rate that will be used if playback were resumed.
@property (assign) double rate;

@property (assign) float volume;
@property BOOL busy;

- (id) initWithURL:(NSURL *)url error:(NSError **)errorPtr;

@end



@protocol LAVPMovieOutput

// Called e.g. after seeking while paused.
-(void) movieOutputNeedsSingleUpdate;
// Called when playback starts or stops for any reason.
-(void) movieOutputNeedsContinuousUpdating:(bool)continuousUpdating;

@end;
