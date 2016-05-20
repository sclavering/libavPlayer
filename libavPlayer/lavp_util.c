/*
 *  Created by Takashi Mochizuki on 11/06/28.
 *  Copyright 2011 MyCometG3. All rights reserved.
 */
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

#include <string.h>

#define CVF_INLINE static inline

CVF_INLINE int CVF_MIN(int a, int b) { return ((a > b) ? b : a); }

void CVF_CopyPlane(const uint8_t* Sbase, int Sstride, int Srow, uint8_t* Dbase, int Dstride, int Drow) {
	// Simple plane copy routine
	// If same stride, it does one memcpy.
	
	int row, stride;
	if(Sstride == Dstride) {
		row = CVF_MIN(Drow, Srow);
		memcpy(Dbase, Sbase, Sstride*row);
	} else {
		int line;
		stride = CVF_MIN(Dstride, Sstride);
		row = CVF_MIN(Drow, Srow);
		for(line=0; line<row; line++) 
			memcpy(Dbase+Dstride*line, Sbase+Sstride*line, stride);
	}
}

#undef CVF_INLINE
