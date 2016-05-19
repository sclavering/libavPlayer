//  Created by Takashi Mochizuki on 11/06/19.
//  Copyright 2011 MyCometG3. All rights reserved.
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

#import "LAVPLayer.h"
#import <GLUT/glut.h>
#import <OpenGL/gl.h>

@import CoreImage;

#define DUMMY_W 640
#define DUMMY_H 480


@implementation LAVPLayer

void MyDisplayReconfigurationCallBack(CGDirectDisplayID display,
                                      CGDisplayChangeSummaryFlags flags,
                                      void *userInfo)
{
    @autoreleasepool {
        if (flags & kCGDisplaySetModeFlag) {
            LAVPLayer *self = (__bridge LAVPLayer *)userInfo;
            dispatch_async(dispatch_get_main_queue(), ^{
                // TODO: Not enough for GPU switching...
                self.asynchronous = NO;
                self.asynchronous = YES;
            } );
        }
    }
}

- (void)invalidate:(NSNotification*)inNotification
{
    self.asynchronous = NO;
    CGDisplayRemoveReconfigurationCallback(MyDisplayReconfigurationCallBack, (__bridge void *)(self));

    [[NSNotificationCenter defaultCenter] removeObserver:self];

    if (_movie) {
        _movie.paused = true;
        _movie = NULL;
    }
    if (_fboId) {
        glDeleteTextures(1, &_fboTextureId);
        glDeleteFramebuffers(1, &_fboId);
        _fboTextureId = 0;
        _fboId = 0;
    }
    if (_lock) _lock = NULL;
    if (_image) _image = NULL;
    if (_ciContext) _ciContext = NULL;
    if (_cglContext) {
        CGLReleaseContext(_cglContext);
        _cglContext = NULL;
    }
    if (_cglPixelFormat) {
        CGLReleasePixelFormat(_cglPixelFormat);
        _cglPixelFormat = NULL;
    }
}

- (void) dealloc
{
    [self invalidate:nil];
}

- (id) init
{
    self = [super init];

    if (self) {
        // FBO Support
        GLint numPixelFormats = 0;
        CGLPixelFormatAttribute attributes[] =
        {
            kCGLPFAAccelerated,
            kCGLPFANoRecovery,
            kCGLPFADoubleBuffer,
            kCGLPFAColorSize, 24,
            kCGLPFAAlphaSize,  8,
            //kCGLPFADepthSize, 16,    // no depth buffer
            kCGLPFAMultisample,
            kCGLPFASampleBuffers, 1,
            kCGLPFASamples, 4,
            0
        };

        CGLChoosePixelFormat(attributes, &_cglPixelFormat, &numPixelFormats);

        if (!_cglPixelFormat) {
            CGLPixelFormatAttribute attributes[] =
            {
                kCGLPFAAccelerated,
                kCGLPFANoRecovery,
                kCGLPFADoubleBuffer,
                kCGLPFAColorSize, 24,
                kCGLPFAAlphaSize,  8,
                //kCGLPFADepthSize, 16,    // no depth buffer
                0
            };

            CGLChoosePixelFormat(attributes, &_cglPixelFormat, &numPixelFormats);
        }
        assert(_cglPixelFormat);

        _cglContext = [super copyCGLContextForPixelFormat:_cglPixelFormat];
        assert(_cglContext);

        /* ========================================================= */

        // Force CGLContext
        CGLContextObj savedContext = CGLGetCurrentContext();
        CGLSetCurrentContext(_cglContext);
        CGLLockContext(_cglContext);

        [self _initOpenGL];

        // Turn on VBL syncing for swaps
        self.asynchronous = YES;

        // Update back buffer size as is
        self.needsDisplayOnBoundsChange = YES;

        // Restore CGLContext
        CGLUnlockContext(_cglContext);
        CGLSetCurrentContext(savedContext);

        /* ========================================================= */

        _lock = [[NSLock alloc] init];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(invalidate:) name:NSApplicationWillTerminateNotification object:nil];

        CGDisplayRegisterReconfigurationCallback(MyDisplayReconfigurationCallBack, (__bridge void *)(self));
    }

    return self;
}

/* =============================================================================================== */
#pragma mark -

- (CGLPixelFormatObj) copyCGLPixelFormatForDisplayMask:(uint32_t)mask
{
    CGLRetainPixelFormat(_cglPixelFormat);
    return _cglPixelFormat;
}

- (CGLContextObj) copyCGLContextForPixelFormat:(CGLPixelFormatObj)pixelFormat
{
    CGLRetainContext(_cglContext);
    return _cglContext;
}

- (BOOL) canDrawInCGLContext:(CGLContextObj)glContext
                 pixelFormat:(CGLPixelFormatObj)pixelFormat
                forLayerTime:(CFTimeInterval)timeInterval
                 displayTime:(const CVTimeStamp *)timeStamp
{
    return _movie && !NSEqualSizes([_movie frameSize], NSZeroSize) && !_movie.busy;
}

- (void) drawInCGLContext:(CGLContextObj)glContext
              pixelFormat:(CGLPixelFormatObj)pixelFormat
             forLayerTime:(CFTimeInterval)timeInterval
              displayTime:(const CVTimeStamp *)timeStamp
{
    if (_movie && !NSEqualSizes([_movie frameSize], NSZeroSize) && !_movie.busy) {
            // Prepare CIImage
            CVPixelBufferRef pb = [_movie getCVPixelBuffer];

            if (pb) {
                [_lock lock];
                _image = [CIImage imageWithCVImageBuffer:pb];
                [self _drawImage];
                [_lock unlock];
                goto bail;
            }
    }

    // Fallback: Use last shown image
    if (_image) {
        [_lock lock];
        [self _drawImage];
        [_lock unlock];
    }

bail:
    // Finishing touch by super class
    [super drawInCGLContext:glContext
                pixelFormat:pixelFormat
               forLayerTime:timeInterval
                displayTime:timeStamp];
}

/* =============================================================================================== */
#pragma mark -
#pragma mark private

- (void) _initOpenGL {
    // Clear to black.
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);

    // Setup blending function
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    // Enable texturing
    glEnable(GL_TEXTURE_RECTANGLE_ARB);
}

/*
 Draw CVImageBuffer into CGLContext
 */
- (void) _drawImage {
    CGLContextObj savedContext = CGLGetCurrentContext();
    CGLSetCurrentContext(_cglContext);
    CGLLockContext(_cglContext);

    if (_movie && !NSEqualSizes([_movie frameSize], NSZeroSize)) {
        // Prepare CIContext
        [self _setCIContext];

        // Prepare new texture
        [self _setFBO];

        // update texture with current CIImage
        [self _renderCoreImageToFBO];

        // Render quad
        [self _renderQuad];

        // Delete the texture and the FBO
        [self _unsetFBO];
    } else {
        NSSize dstSize = [self bounds].size;

        // Set up canvas
        glViewport(0, 0, dstSize.width, dstSize.height);

        glMatrixMode(GL_PROJECTION);
        glLoadIdentity();

        glMatrixMode(GL_MODELVIEW);    // select the modelview matrix
        glLoadIdentity();              // reset it

        glClearColor(0 , 0 , 0 , 1);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    }

    CGLUnlockContext(_cglContext);
    CGLSetCurrentContext(savedContext);

    CGLFlushDrawable(_cglContext);
}

- (void) _setCIContext
{
    if(_ciContext) return;
    _ciContext = [CIContext contextWithCGLContext:_cglContext pixelFormat:_cglPixelFormat colorSpace:NULL options:NULL];
}

/*
 Set up FBO and new Texture
 */
- (void) _setFBO
{
    if (!_fboId) {
        // create FBO object
        glGenFramebuffers(1, &_fboId);
        assert(_fboId);

        // create texture
        glGenTextures(1, &_fboTextureId);
        assert(_fboTextureId);

        // Bind FBO
        GLint saved_fboId = 0;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &saved_fboId);
        glBindFramebuffer(GL_FRAMEBUFFER, _fboId);

        // Bind texture
        glBindTexture(GL_TEXTURE_RECTANGLE_ARB, _fboTextureId);

        // Prepare GL_BGRA texture attached to FBO
        glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

        glTexImage2D(GL_TEXTURE_RECTANGLE_ARB, 0, GL_RGBA, _textureRect.size.width, _textureRect.size.height,
                     0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, NULL);

        // Attach texture to the FBO as its color destination
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE_ARB, _fboTextureId, 0);

        // Make sure the FBO was created succesfully.
        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (GL_FRAMEBUFFER_COMPLETE != status) {
            NSString* statusStr = @"OTHER ERROR";
            if (GL_FRAMEBUFFER_UNSUPPORTED == status) {
                statusStr = @"GL_FRAMEBUFFER_UNSUPPORTED";
            } else if (GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT == status) {
                statusStr = @"GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT";
            } else if (GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT == status) {
                statusStr = @"GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT";
            }
            NSLog(@"ERROR: glFramebufferTexture2D() failed! (0x%04x:%@)", status, statusStr);
            assert(GL_FRAMEBUFFER_COMPLETE != status);
        }

        // unbind texture
        glBindTexture(GL_TEXTURE_RECTANGLE_ARB, 0);

        // unbind FBO
        glBindFramebuffer(GL_FRAMEBUFFER, saved_fboId);
    }
}

- (void) _renderCoreImageToFBO
{
    // Same approach; CoreImageGLTextureFBO - MyOpenGLView.m - renderCoreImageToFBO

    // Bind FBO
    GLint   saved_fboId = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &saved_fboId);
    glBindFramebuffer(GL_FRAMEBUFFER, _fboId);

    {
        // prepare canvas
        GLint width = (GLint)ceil(_textureRect.size.width);
        GLint height = (GLint)ceil(_textureRect.size.height);

        glViewport(0, 0, width, height);

        glMatrixMode(GL_PROJECTION);
        glLoadIdentity();

        glOrtho(0, width, 0, height, -1, 1);

        glMatrixMode(GL_MODELVIEW);
        glLoadIdentity();

        glClear(GL_COLOR_BUFFER_BIT);

        [_ciContext drawImage:_image inRect:_textureRect fromRect:[_image extent]];
    }

    // Unbind FBO
    glBindFramebuffer(GL_FRAMEBUFFER, saved_fboId);
}

- (void) _renderQuad
{
    CGSize tr = CGSizeMake( 1.0f,  1.0f);
    CGSize tl = CGSizeMake(-1.0f,  1.0f);
    CGSize bl = CGSizeMake(-1.0f, -1.0f);
    CGSize br = CGSizeMake( 1.0f, -1.0f);
    if(!self.stretchVideoToFitLayer) {
        CGSize ls = [self bounds].size;
        CGSize vs = [_movie frameSize];
        CGFloat hRatio = vs.width / ls.width;
        CGFloat vRatio = vs.height / ls.height;
        CGFloat layerAspect = ls.width / ls.height;
        CGFloat videoAspect = vs.width / vs.height;
        // If layer is wider aspect ratio than video
        if(layerAspect > videoAspect) {
            tr = CGSizeMake( hRatio / vRatio,  1.0f);
            tl = CGSizeMake(-hRatio / vRatio,  1.0f);
            bl = CGSizeMake(-hRatio / vRatio, -1.0f);
            br = CGSizeMake( hRatio / vRatio, -1.0f);
        } else {
            tr = CGSizeMake( 1.0f,  vRatio / hRatio);
            tl = CGSizeMake(-1.0f,  vRatio / hRatio);
            bl = CGSizeMake(-1.0f, -vRatio / hRatio);
            br = CGSizeMake( 1.0f, -vRatio / hRatio);
        }
    }

    // Same approach; CoreImageGLTextureFBO - MyOpenGLView.m - renderScene

    // prepare canvas
    glViewport(0, 0, [self bounds].size.width, [self bounds].size.height);

    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();

    glMatrixMode(GL_TEXTURE);
    glLoadIdentity();

    glScalef(_textureRect.size.width, _textureRect.size.height, 1.0f);

    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();

    // clear
    glClear(GL_COLOR_BUFFER_BIT);

    // Bind Texture
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, _fboTextureId);
    glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);

    //glPushMatrix();
    {
        // Draw simple quad with texture image
        glBegin(GL_QUADS);

        glTexCoord2f( 1.0f, 1.0f ); glVertex2f( tr.width, tr.height );
        glTexCoord2f( 0.0f, 1.0f ); glVertex2f( tl.width, tl.height );
        glTexCoord2f( 0.0f, 0.0f ); glVertex2f( bl.width, bl.height );
        glTexCoord2f( 1.0f, 0.0f ); glVertex2f( br.width, br.height );

        glEnd();
    }
    //glPopMatrix();

    // Unbind Texture
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, 0);
}

- (void) _unsetFBO {
    if (_fboId) {
        glDeleteTextures(1, &_fboTextureId);
        glDeleteFramebuffers(1, &_fboId);
        _fboTextureId = 0;
        _fboId = 0;
    }
}

/* =============================================================================================== */
#pragma mark -
#pragma mark public

- (LAVPMovie *) movie
{
    return _movie;
}

- (void) setMovie:(LAVPMovie *)movie
{
    self.asynchronous = NO;
    [_lock lock];

    if (_fboId) {
        glDeleteTextures(1, &_fboTextureId);
        glDeleteFramebuffers(1, &_fboId);
        _fboTextureId = 0;
        _fboId = 0;
    }

    if(_movie) {
        _movie.paused = true;
        _movie.movieOutput = nil;
    }
    _movie = movie;
    _movie.movieOutput = self;

    // Get the size of the image we are going to need throughout
    if (_movie && [_movie frameSize].width && [_movie frameSize].height)
        _textureRect = CGRectMake(0, 0, [_movie frameSize].width, [_movie frameSize].height);
    else
        _textureRect = CGRectMake(0, 0, DUMMY_W, DUMMY_H);

    // Get the aspect ratio for possible scaling (e.g. texture coordinates)
    _imageAspectRatio = _textureRect.size.width / _textureRect.size.height;

    // Shrink texture size if it is bigger than limit
    GLint maxTexSize;
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxTexSize);
    if (_textureRect.size.width > maxTexSize || _textureRect.size.height > maxTexSize) {
        if (_imageAspectRatio > 1) {
            _textureRect.size.width = maxTexSize;
            _textureRect.size.height = maxTexSize / _imageAspectRatio;
        } else {
            _textureRect.size.width = maxTexSize * _imageAspectRatio;
            _textureRect.size.height = maxTexSize;
        }
    }

    [self setNeedsDisplay];

    [_lock unlock];
    self.asynchronous = YES;
}

/* =============================================================================================== */
#pragma mark -
#pragma mark LAVPMovieOutput impl

// Called e.g. after seeking while paused.
-(void) movieOutputNeedsSingleUpdate {
    [self setNeedsDisplay];
}

// Called when playback starts or stops for any reason.
-(void) movieOutputNeedsContinuousUpdating:(bool)continuousUpdating {
    self.asynchronous = continuousUpdating;
}

@end
