void copy_planar_YUV420_to_2vuy(size_t width, size_t height,
                               uint8_t *baseAddr_y, size_t rowBytes_y,
                               uint8_t *baseAddr_u, size_t rowBytes_u,
                               uint8_t *baseAddr_v, size_t rowBytes_v,
                               uint8_t *baseAddr_2vuy, size_t rowBytes_2vuy);
void CVF_CopyPlane(const UInt8* Sbase, int Sstride, int Srow, UInt8* Dbase, int Dstride, int Drow);
