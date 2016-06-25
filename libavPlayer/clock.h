int64_t clock_get_usec(MovieState *mov);
void clock_set_at(MovieState *mov, int64_t pts, int serial, int64_t time);
void clock_set(MovieState *mov, int64_t pts, int serial);
void clock_preserve(MovieState *mov);
void clock_init(MovieState *mov);
