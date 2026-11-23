#ifndef PS5T_ARABIC_FONT_ATLAS_H
#define PS5T_ARABIC_FONT_ATLAS_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t codepoint;
    uint16_t atlas_x;
    uint16_t atlas_y;
    uint16_t w;
    uint16_t h;
    int16_t  xoff;
    int16_t  yoff;
    int16_t  xadvance;
    bool     valid;
} ps5t_glyph_t;

bool font_atlas_init(const char* primary_ttf, const char* fallback_ttf, float pixel_height);
void font_atlas_shutdown(void);
bool font_atlas_is_ready(void);

/* Decodes next UTF-8 codepoint and advances *ptr */
uint32_t font_utf8_next(const char** ptr);

/* Looks up a baked glyph (Basic Latin + Arabic + Arabic Presentation Forms A/B) */
const ps5t_glyph_t* font_atlas_get_glyph(uint32_t codepoint);

/* Measures pixel width of a single line of UTF-8 text */
int32_t font_atlas_measure_line(const char* utf8_line, int32_t byte_len);

/* Accessors for atlas alpha bitmap and vertical metrics */
const uint8_t* font_atlas_bitmap(int32_t* out_w, int32_t* out_h);
int32_t font_atlas_line_height(void);
int32_t font_atlas_ascent(void);

#ifdef __cplusplus
}
#endif

#endif /* PS5T_ARABIC_FONT_ATLAS_H */
