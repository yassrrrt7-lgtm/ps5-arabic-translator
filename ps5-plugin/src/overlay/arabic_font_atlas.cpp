#include "arabic_font_atlas.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

/* Compact 1024x1024 8-bit alpha atlas (1 MB static RAM, zero runtime allocations) */
#define ATLAS_W 1024
#define ATLAS_H 1024
#define MAX_BAKED_GLYPHS 1024

static uint8_t      s_atlas_bmp[ATLAS_W * ATLAS_H];
static ps5t_glyph_t s_glyphs[MAX_BAKED_GLYPHS];
static int32_t      s_glyph_count = 0;
static int32_t      s_line_height = 36;
static int32_t      s_ascent = 28;
static bool         s_ready = false;

static void bake_range(
    const stbtt_fontinfo* font,
    float scale,
    uint32_t cp_start,
    uint32_t cp_end,
    int32_t* pen_x,
    int32_t* pen_y,
    int32_t* row_h
) {
    for (uint32_t cp = cp_start; cp <= cp_end; ++cp) {
        if (s_glyph_count >= MAX_BAKED_GLYPHS) return;

        int glyph_idx = stbtt_FindGlyphIndex(font, (int)cp);
        if (glyph_idx == 0 && cp != 0x0020) continue;

        int adv = 0, lsb = 0;
        stbtt_GetGlyphHMetrics(font, glyph_idx, &adv, &lsb);

        int x0 = 0, y0 = 0, x1 = 0, y1 = 0;
        stbtt_GetGlyphBitmapBox(font, glyph_idx, scale, scale, &x0, &y0, &x1, &y1);
        int gw = x1 - x0;
        int gh = y1 - y0;

        if (*pen_x + gw + 2 >= ATLAS_W) {
            *pen_x = 2;
            *pen_y += (*row_h + 2);
            *row_h = 0;
        }
        if (*pen_y + gh + 2 >= ATLAS_H) {
            return;
        }

        if (gw > 0 && gh > 0) {
            uint8_t* dst = s_atlas_bmp + (*pen_y * ATLAS_W) + *pen_x;
            stbtt_MakeGlyphBitmap(font, dst, gw, gh, ATLAS_W, scale, scale, glyph_idx);
        }

        ps5t_glyph_t* g = &s_glyphs[s_glyph_count++];
        g->codepoint = cp;
        g->atlas_x   = (uint16_t)(*pen_x);
        g->atlas_y   = (uint16_t)(*pen_y);
        g->w         = (uint16_t)(gw > 0 ? gw : 0);
        g->h         = (uint16_t)(gh > 0 ? gh : 0);
        g->xoff      = (int16_t)x0;
        g->yoff      = (int16_t)y0;
        g->xadvance  = (int16_t)lrintf((float)adv * scale);
        g->valid     = true;

        *pen_x += (gw + 2);
        if (gh > *row_h) *row_h = gh;
    }
}

static uint8_t* load_file_bytes(const char* path, size_t* out_size) {
    if (!path) return NULL;
    FILE* f = fopen(path, "rb");
    if (!f) return NULL;

    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    if (sz <= 0 || sz > 16 * 1024 * 1024) {
        fclose(f);
        return NULL;
    }
    fseek(f, 0, SEEK_SET);

    uint8_t* buf = (uint8_t*)malloc((size_t)sz);
    if (!buf) {
        fclose(f);
        return NULL;
    }
    size_t read_n = fread(buf, 1, (size_t)sz, f);
    fclose(f);

    if (read_n != (size_t)sz) {
        free(buf);
        return NULL;
    }
    *out_size = read_n;
    return buf;
}

extern "C" bool font_atlas_init(const char* primary_ttf, const char* fallback_ttf, float pixel_height) {
    font_atlas_shutdown();

    size_t ttf_size = 0;
    uint8_t* ttf_data = load_file_bytes(primary_ttf, &ttf_size);
    if (!ttf_data && fallback_ttf) {
        ttf_data = load_file_bytes(fallback_ttf, &ttf_size);
    }
    if (!ttf_data) {
        return false;
    }

    stbtt_fontinfo font;
    if (!stbtt_InitFont(&font, ttf_data, stbtt_GetFontOffsetForIndex(ttf_data, 0))) {
        free(ttf_data);
        return false;
    }

    float scale = stbtt_ScaleForPixelHeight(&font, pixel_height);
    int ascent = 0, descent = 0, line_gap = 0;
    stbtt_GetFontVMetrics(&font, &ascent, &descent, &line_gap);
    s_ascent = (int32_t)lrintf((float)ascent * scale);
    s_line_height = (int32_t)lrintf((float)(ascent - descent + line_gap) * scale);
    if (s_line_height < (int32_t)pixel_height) {
        s_line_height = (int32_t)pixel_height + 4;
    }

    memset(s_atlas_bmp, 0, sizeof(s_atlas_bmp));
    s_glyph_count = 0;

    int32_t pen_x = 2, pen_y = 2, row_h = 0;
    /* 1. Basic Latin (ASCII: numbers, English words, punctuation) */
    bake_range(&font, scale, 0x0020, 0x007E, &pen_x, &pen_y, &row_h);
    /* 2. Standard Arabic block */
    bake_range(&font, scale, 0x0600, 0x06FF, &pen_x, &pen_y, &row_h);
    /* 3. Arabic Presentation Forms-B (all shaped isolated/initial/medial/final + Lam-Alef) */
    bake_range(&font, scale, 0xFE70, 0xFEFF, &pen_x, &pen_y, &row_h);
    /* 4. Selected Arabic Presentation Forms-A */
    bake_range(&font, scale, 0xFB50, 0xFBB1, &pen_x, &pen_y, &row_h);

    free(ttf_data);
    s_ready = (s_glyph_count > 0);
    return s_ready;
}

extern "C" void font_atlas_shutdown(void) {
    s_ready = false;
    s_glyph_count = 0;
}

extern "C" bool font_atlas_is_ready(void) {
    return s_ready;
}

extern "C" uint32_t font_utf8_next(const char** ptr) {
    const uint8_t* s = (const uint8_t*)(*ptr);
    if (!s || *s == 0) return 0;

    uint32_t cp = 0;
    if (s[0] < 0x80) {
        cp = s[0];
        *ptr += 1;
    } else if ((s[0] & 0xE0) == 0xC0 && s[1]) {
        cp = ((uint32_t)(s[0] & 0x1F) << 6) | (uint32_t)(s[1] & 0x3F);
        *ptr += 2;
    } else if ((s[0] & 0xF0) == 0xE0 && s[1] && s[2]) {
        cp = ((uint32_t)(s[0] & 0x0F) << 12) |
             ((uint32_t)(s[1] & 0x3F) << 6) |
             (uint32_t)(s[2] & 0x3F);
        *ptr += 3;
    } else if ((s[0] & 0xF8) == 0xF0 && s[1] && s[2] && s[3]) {
        cp = ((uint32_t)(s[0] & 0x07) << 18) |
             ((uint32_t)(s[1] & 0x3F) << 12) |
             ((uint32_t)(s[2] & 0x3F) << 6) |
             (uint32_t)(s[3] & 0x3F);
        *ptr += 4;
    } else {
        cp = '?';
        *ptr += 1;
    }
    return cp;
}

extern "C" const ps5t_glyph_t* font_atlas_get_glyph(uint32_t codepoint) {
    /* Linear/binary search over sorted range blocks */
    for (int32_t i = 0; i < s_glyph_count; ++i) {
        if (s_glyphs[i].codepoint == codepoint) {
            return &s_glyphs[i];
        }
    }
    return NULL;
}

extern "C" int32_t font_atlas_measure_line(const char* utf8_line, int32_t byte_len) {
    if (!utf8_line || byte_len <= 0) return 0;
    const char* p = utf8_line;
    const char* end = utf8_line + byte_len;
    int32_t width = 0;
    while (p < end && *p) {
        uint32_t cp = font_utf8_next(&p);
        const ps5t_glyph_t* g = font_atlas_get_glyph(cp);
        if (g) {
            width += g->xadvance;
        }
    }
    return width;
}

extern "C" const uint8_t* font_atlas_bitmap(int32_t* out_w, int32_t* out_h) {
    if (out_w) *out_w = ATLAS_W;
    if (out_h) *out_h = ATLAS_H;
    return s_atlas_bmp;
}

extern "C" int32_t font_atlas_line_height(void) {
    return s_line_height;
}

extern "C" int32_t font_atlas_ascent(void) {
    return s_ascent;
}
