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
#import "LAVPMovie+Internal.h"

#import <OpenGL/gl3.h>


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
    [self _gl_cleanup];
    if (_movie) {
        _movie.paused = true;
        _movie = NULL;
    }
    if (_lock) _lock = NULL;
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
            kCGLPFAOpenGLProfile, kCGLOGLPVersion_GL3_Core,
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
        assert(_cglPixelFormat);

        _cglContext = [super copyCGLContextForPixelFormat:_cglPixelFormat];
        assert(_cglContext);

        /* ========================================================= */

        CGLSetCurrentContext(_cglContext);
        CGLLockContext(_cglContext);

        [self _gl_init];

        // Update back buffer size as is
        self.needsDisplayOnBoundsChange = YES;

        CGLUnlockContext(_cglContext);

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
    return _movie && !NSEqualSizes([_movie frameSize], NSZeroSize);
}

- (void) drawInCGLContext:(CGLContextObj)glContext
              pixelFormat:(CGLPixelFormatObj)pixelFormat
             forLayerTime:(CFTimeInterval)timeInterval
              displayTime:(const CVTimeStamp *)timeStamp
{
    [self _gl_draw];
    [super drawInCGLContext:glContext
                pixelFormat:pixelFormat
               forLayerTime:timeInterval
                displayTime:timeStamp];
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

    if(_movie) {
        _movie.paused = true;
        _movie.movieOutput = nil;
    }
    _movie = movie;
    _movie.movieOutput = self;

    [self setNeedsDisplay];

    [_lock unlock];
    self.asynchronous = !movie.paused;
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


/* =============================================================================================== */

#pragma mark -
#pragma mark OpenGL-based drawing code

static const char *const vertex_shader_src = "                               \
    #version 330 core                                                        \
    layout(location = 0) in vec3 vertexPosition_modelspace;                  \
    layout(location = 1) in vec2 vertexUV;                                   \
    out vec2 texcoord;                                                       \
    void main() {                                                            \
        gl_Position.xyz = vertexPosition_modelspace;                         \
        texcoord = vertexUV;                                                 \
    }                                                                        \
";

static const char *const fragment_shader_src = "                             \
    #version 330 core                                                        \
    in vec2 texcoord;                                                        \
    out vec3 color;                                                          \
    uniform sampler2D video_data_y;                                          \
    uniform sampler2D video_data_u;                                          \
    uniform sampler2D video_data_v;                                          \
    void main() {                                                            \
        float y = texture(video_data_y, texcoord).r;                         \
        float u = texture(video_data_u, texcoord).r - 0.5;                   \
        float v = texture(video_data_v, texcoord).r - 0.5;                   \
        float r = y + 1.402 * v;                                             \
        float g = y - 0.344 * u - 0.714 * v;                                 \
        float b = y + 1.772 * u;                                             \
        color = vec3(r, g, b);                                               \
    }                                                                        \
";

- (void) _gl_init {
    _program = load_shaders(vertex_shader_src, fragment_shader_src) ;
    _location_y = glGetUniformLocation(_program, "video_data_y");
    _location_u = glGetUniformLocation(_program, "video_data_u");
    _location_v = glGetUniformLocation(_program, "video_data_v");

    const GLfloat vertex_data[] = {
        -1.0f, -1.0f, 0.0f,
        1.0f, -1.0f, 0.0f,
        -1.0f, 1.0f, 0.0f,
        1.0f, 1.0f, 0.0f,
    };
    glGenBuffers(1, &_vertex_buffer);
    glBindBuffer(GL_ARRAY_BUFFER, _vertex_buffer);
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertex_data), vertex_data, GL_STATIC_DRAW);

    const GLfloat texture_vertex_data[] = {
        0.0f, 1.0f,
        1.0f, 1.0f,
        0.0f, 0.0f,
        1.0f, 0.0f,
    };
    glGenBuffers(1, &_texture_vertex_buffer);
    glBindBuffer(GL_ARRAY_BUFFER, _texture_vertex_buffer);
    glBufferData(GL_ARRAY_BUFFER, sizeof(texture_vertex_data), texture_vertex_data, GL_STATIC_DRAW);

    glGenTextures(3, _textures);
    for(int i = 0; i < 3; ++i) {
        glBindTexture(GL_TEXTURE_2D, _textures[i]);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    }
}

GLuint load_shaders(const char * VertexShaderCode, const char * FragmentShaderCode) {
    GLuint vertex_shader_id = init_shader(GL_VERTEX_SHADER, VertexShaderCode);
    GLuint fragment_shader_id = init_shader(GL_FRAGMENT_SHADER, FragmentShaderCode);

    GLuint prog_id = glCreateProgram();
    glAttachShader(prog_id, vertex_shader_id);
    glAttachShader(prog_id, fragment_shader_id);
    glLinkProgram(prog_id);

    GLint Result = GL_FALSE;
    glGetProgramiv(prog_id, GL_LINK_STATUS, &Result);
    int info_log_length;
    glGetProgramiv(prog_id, GL_INFO_LOG_LENGTH, &info_log_length);
    if(info_log_length > 0) {
        char* err = malloc(info_log_length + 1);
        glGetProgramInfoLog(prog_id, info_log_length, NULL, err);
        NSLog(@"LAVPLayer: error linking shader:\n%s", err);
        free(err);
        return 0;
    }

    glDetachShader(prog_id, vertex_shader_id);
    glDetachShader(prog_id, fragment_shader_id);
    glDeleteShader(vertex_shader_id);
    glDeleteShader(fragment_shader_id);
    return prog_id;
}

GLuint init_shader(GLenum kind, const char* code) {
    GLuint shader_id = glCreateShader(kind);
    glShaderSource(shader_id, 1, &code , NULL);
    glCompileShader(shader_id);
    GLint Result = GL_FALSE;
    glGetShaderiv(shader_id, GL_COMPILE_STATUS, &Result);
    int info_log_length;
    glGetShaderiv(shader_id, GL_INFO_LOG_LENGTH, &info_log_length);
    if(info_log_length > 0) {
        char* err = malloc(info_log_length + 1);
        glGetShaderInfoLog(shader_id, info_log_length, NULL, err);
        NSLog(@"LAVPLayer: error compiling shader:\n%s", err);
        free(err);
        return 0;
    }
    return shader_id;
}

- (void) _gl_cleanup {
    if(_textures[0]) glDeleteTextures(3, _textures);
    for(int i = 0; i < 3; ++i) _textures[i] = 0;
    if(_vertex_buffer) glDeleteBuffers(1, &_vertex_buffer);
    _vertex_buffer = 0;
    if(_texture_vertex_buffer) glDeleteBuffers(1, &_texture_vertex_buffer);
    _texture_vertex_buffer = 0;
    if(_program) glDeleteProgram(_program);
    _program = 0;
}

- (void) _gl_draw {
    [_lock lock];
    Frame* frm = [_movie getCurrentFrame];

    // We always need to re-render, but if the frame is unchanged we don't upload new texture data).
    if(frm) {
        NSSize sz = [_movie sizeForGLTextures];
        glBindTexture(GL_TEXTURE_2D, _textures[0]);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, frm->frm_bmp->linesize[0]);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RED, sz.width, sz.height, 0, GL_RED, GL_UNSIGNED_BYTE, frm->frm_bmp->data[0]);
        glBindTexture(GL_TEXTURE_2D, _textures[1]);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, frm->frm_bmp->linesize[1]);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RED, sz.width / 2, sz.height / 2, 0, GL_RED, GL_UNSIGNED_BYTE, frm->frm_bmp->data[1]);
        glBindTexture(GL_TEXTURE_2D, _textures[2]);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, frm->frm_bmp->linesize[2]);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RED, sz.width / 2, sz.height / 2, 0, GL_RED, GL_UNSIGNED_BYTE, frm->frm_bmp->data[2]);
    }

    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    GLuint vertex_array_id;
    glGenVertexArrays(1, &vertex_array_id);
    glBindVertexArray(vertex_array_id);

    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    glUseProgram(_program);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, _textures[0]);
    glUniform1i(_location_y, 0);

    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, _textures[1]);
    glUniform1i(_location_u, 1);

    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, _textures[2]);
    glUniform1i(_location_v, 2);

    glEnableVertexAttribArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, _vertex_buffer);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, NULL);

    glEnableVertexAttribArray(1);
    glBindBuffer(GL_ARRAY_BUFFER, _texture_vertex_buffer);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, NULL);

    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);

    glDeleteVertexArrays(1, &vertex_array_id);

    [_lock unlock];
}

@end
