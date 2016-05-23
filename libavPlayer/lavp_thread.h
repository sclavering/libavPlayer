//
//  lavp_thread.h
//  libavPlayer
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

#include <pthread.h>

pthread_cond_t* lavp_pthread_cond_create(void);
void lavp_pthread_cond_destroy(pthread_cond_t *cond);
void lavp_pthread_cond_wait_with_timeout(pthread_cond_t *cond, pthread_mutex_t *mutex, int ms);

pthread_mutex_t* lavp_pthread_mutex_create(void);
void lavp_pthread_mutex_destroy(pthread_mutex_t *mutex);
