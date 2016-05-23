//
//  Created by Takashi Mochizuki on 11/07/27.
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

#import "lavp_thread.h"

#include <stdlib.h>
#include <assert.h>
#include <mach/mach_time.h>
#include <sys/time.h>

void lavp_pthread_cond_wait_with_timeout(pthread_cond_t *cond, pthread_mutex_t *mutex, int ms)
{
    if (ms <= 0)
        ms = 1;
    
    struct timeval  now; /* usec = 1/1000000 */
    struct timespec limit; /* nsec = 1/1000000000 */
    long dt_sec, dt_nsec;
    
    // not strict but enough in msec order
    dt_sec = (long)ms / 1000L;
    dt_nsec = (long)ms * 1000000L - dt_sec * 1000000000L;
    
    gettimeofday(&now, NULL);
    limit.tv_sec = now.tv_sec + dt_sec;
    limit.tv_nsec = now.tv_usec * 1000L + dt_nsec;
    
    while (limit.tv_nsec > 1000000000L) {
        limit.tv_sec ++;
        limit.tv_nsec -= 1000000000L;
    }
    
    // Do a timed wait
    pthread_cond_timedwait( cond, mutex, &limit );
}

void lavp_pthread_cond_destroy(pthread_cond_t *cond)
{
	//assert(cond);
	
	pthread_cond_destroy(cond);
	free(cond);
}

pthread_cond_t* lavp_pthread_cond_create()
{
	pthread_cond_t *cond = calloc(1, sizeof(pthread_cond_t));
	int result = pthread_cond_init(cond, NULL);
	assert(!result);
	return cond;
}

void lavp_pthread_mutex_destroy(pthread_mutex_t *mutex)
{
	//assert(mutex);
	
	pthread_mutex_destroy(mutex);
	free(mutex);
}

pthread_mutex_t* lavp_pthread_mutex_create()
{
	pthread_mutex_t *mutex = calloc(1, sizeof(pthread_mutex_t));
	int result = pthread_mutex_init(mutex, NULL);
	assert(!result);
	return mutex;
}

