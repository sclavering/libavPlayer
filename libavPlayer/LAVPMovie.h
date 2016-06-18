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
}

@property (retain, readonly) NSURL *url;

@property (readonly) NSSize naturalSize;
@property (readonly) int64_t durationInMicroseconds;
@property (assign) int64_t currentTimeInMicroseconds;

// How far along we are in playing the movie.  0.0 for the start, and 1.0 for the end.
@property (assign) double currentTimeAsFraction;

// Movies start out paused.  Set this to start/stop playing.
@property BOOL paused;

// Normally 100.  Adjust this to play faster or slower.  Pausing is separate from speed, i.e. if accessed while paused this returns the speed that will be used if playback were resumed.  This is an integer percentage (rather than a double fraction) to make accumulated rounding errors impossible.
@property (assign) int playbackSpeedPercent;

// Normally 100.  This is an integer percentage (rather than a float fraction) to make accumulated rounding errors impossible.
@property (assign) int volumePercent;

-(instancetype) initWithURL:(NSURL *)url error:(NSError **)errorPtr NS_DESIGNATED_INITIALIZER;

// Typically an LAVPLayer should be passed to this.  It's used to start/stop updating when paused/unpaused (so the layer doesn't waste tons of CPU), and also to explicitly update if seeking while paused.  The argument is held as a weak reference.
-(void) setOutput:(id<LAVPMovieOutput>)output;

-(void) invalidate;
@end



@protocol LAVPMovieOutput

// Called when playback starts or stops for any reason.
-(void) movieOutputNeedsContinuousUpdating:(bool)continuousUpdating;

@end;
