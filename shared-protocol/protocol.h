#ifndef PS5_TRANSLATOR_PROTOCOL_H
#define PS5_TRANSLATOR_PROTOCOL_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * PS5 <-> iPhone Ultra-Low-Latency Binary UDP Protocol (v1)
 * Endianness : Little-Endian (native on both PS5 x86-64 and iPhone ARM64)
 * Transport  : Dual-Mode (Direct LAN 10.0.0.1 <-> 10.0.0.2 + Wi-Fi Broadcast)
 * ============================================================================ */

/* Magic bytes: "PS5T" in little-endian memory order (0x50, 0x53, 0x35, 0x54) */
#define PS5T_MAGIC              0x54355350U
#define PS5T_PROTOCOL_VERSION   1U

/* Network endpoints & ports */
#define PS5T_PORT_DISCOVERY     55000U
#define PS5T_PORT_DATA          55001U
#define PS5T_LAN_PS5_IP         "10.0.0.1"
#define PS5T_LAN_IPHONE_IP      "10.0.0.2"

/* Strict MTU & payload budgets (guarantees zero IP fragmentation) */
#define PS5T_MAX_UDP_PACKET     1400U
#define PS5T_MAX_CHUNK_DATA     1344U   /* 40-byte ROI header + 1344 = 1384 bytes */
#define PS5T_MAX_ROI_BYTES      20480U  /* Hard 20 KB cap per subtitle capture */
#define PS5T_MAX_CHUNKS         16U     /* 16 * 1344 = 21,504 >= 20,480 bytes */
#define PS5T_TITLE_ID_LEN       16U     /* Null-padded ASCII e.g. "PPSA01234" */
#define PS5T_MAX_UTF8_BYTES     1024U   /* Fits full shaped Arabic subtitle in 1 UDP packet */

/* Failover & keepalive timing (milliseconds) */
#define PS5T_HEARTBEAT_INTERVAL_MS  500U
#define PS5T_FAILOVER_TIMEOUT_MS    1000U

/* Packet types */
typedef enum {
    PKT_DISCOVER            = 0x01, /* PS5 -> Broadcast:55000 (Wi-Fi discovery) */
    PKT_DISCOVER_ACK        = 0x02, /* iPhone -> PS5 (returns IP + readiness) */
    PKT_ROI_FRAME           = 0x03, /* PS5 -> iPhone:55001 (chunked ROI pixels) */
    PKT_TRANSLATION_STREAM  = 0x04, /* iPhone -> PS5 (cumulative shaped Arabic UTF-8) */
    PKT_HEARTBEAT           = 0x05, /* PS5 -> iPhone:55001 (keepalive / RTT probe) */
    PKT_HEARTBEAT_ACK       = 0x06  /* iPhone -> PS5 (keepalive reply + thermal status) */
} ps5t_pkt_type_t;

/* Pixel formats for ROI crops */
typedef enum {
    PIXFMT_GRAY8            = 0x01, /* 8-bit grayscale (1 byte/px, default for OCR) */
    PIXFMT_GRAY8_RLE        = 0x02, /* Fast RLE-compressed 8-bit grayscale */
    PIXFMT_RGB565           = 0x03  /* 16-bit RGB565 (2 bytes/px, optional fallback) */
} ps5t_pixel_format_t;

/* Transport identifiers */
typedef enum {
    TRANSPORT_UNKNOWN       = 0x00,
    TRANSPORT_LAN           = 0x01, /* Direct Ethernet 10.0.0.1 <-> 10.0.0.2 */
    TRANSPORT_WIFI          = 0x02  /* Local Wi-Fi / Hotspot */
} ps5t_transport_t;

/* ROI frame flags */
#define ROI_FLAG_FORCE_REFRESH  (1U << 0) /* Bypass SQLite cache on iPhone */

/* Translation stream flags */
#define TRANS_FLAG_FINAL        (1U << 0) /* Final completed translation for frame_id */
#define TRANS_FLAG_CACHE_HIT    (1U << 1) /* Served instantly from SQLite cache */
#define TRANS_FLAG_CLEAR        (1U << 2) /* Clear overlay (no subtitle detected in ROI) */

/* Heartbeat ACK status flags */
#define STATUS_MODEL_READY      (1U << 0) /* Offline LLM is loaded on Metal GPU */
#define STATUS_THERMAL_WARN     (1U << 1) /* iPhone thermalState is serious/critical */

#if defined(__GNUC__) || defined(__clang__)
#define PS5T_PACKED __attribute__((packed))
#else
#define PS5T_PACKED
#endif

/* Common 8-byte header prepended to every UDP datagram */
typedef struct PS5T_PACKED {
    uint32_t magic;        /* Must equal PS5T_MAGIC */
    uint8_t  version;      /* Must equal PS5T_PROTOCOL_VERSION */
    uint8_t  type;         /* ps5t_pkt_type_t */
    uint16_t payload_len;  /* Byte length following this 8-byte header */
} ps5t_header_t;

/* 1. PKT_DISCOVER (28 bytes) */
typedef struct PS5T_PACKED {
    ps5t_header_t hdr;
    uint32_t      client_nonce;
    char          title_id[PS5T_TITLE_ID_LEN];
} ps5t_pkt_discover_t;

/* 2. PKT_DISCOVER_ACK (16 bytes) */
typedef struct PS5T_PACKED {
    ps5t_header_t hdr;
    uint32_t      client_nonce;
    uint16_t      data_port;      /* Normally PS5T_PORT_DATA (55001) */
    uint8_t       transport_hint; /* ps5t_transport_t */
    uint8_t       server_ready;   /* 1 = ready, 0 = loading model */
} ps5t_pkt_discover_ack_t;

/* 3. PKT_ROI_FRAME header (40 bytes + chunk_bytes pixel data immediately following) */
typedef struct PS5T_PACKED {
    ps5t_header_t hdr;
    uint32_t      frame_id;
    char          title_id[PS5T_TITLE_ID_LEN];
    uint16_t      width;
    uint16_t      height;
    uint8_t       pixel_format;   /* ps5t_pixel_format_t */
    uint8_t       chunk_index;    /* 0 .. total_chunks - 1 */
    uint8_t       total_chunks;   /* 1 .. PS5T_MAX_CHUNKS */
    uint8_t       flags;          /* ROI_FLAG_* */
    uint16_t      chunk_bytes;    /* Actual pixel bytes in this packet (<= 1344) */
    uint16_t      reserved;       /* Must be 0 */
} ps5t_pkt_roi_frame_hdr_t;

/* 4. PKT_TRANSLATION_STREAM header (20 bytes + utf8_byte_length bytes immediately following)
 * Note: Payload carries the CUMULATIVE pre-shaped & BiDi-reordered Arabic UTF-8 string
 * for frame_id (NOT null-terminated on the wire) so any dropped UDP packet self-heals
 * on the very next streamed token without corrupting Arabic visual order. */
typedef struct PS5T_PACKED {
    ps5t_header_t hdr;
    uint32_t      frame_id;
    uint16_t      seq_num;          /* Monotonic token update sequence for frame_id */
    uint16_t      utf8_byte_length; /* <= PS5T_MAX_UTF8_BYTES */
    uint8_t       flags;            /* TRANS_FLAG_* */
    uint8_t       reserved;         /* Must be 0 */
    uint16_t      latency_ms;       /* Server-side processing ms since frame arrival */
} ps5t_pkt_translation_hdr_t;

/* 5. PKT_HEARTBEAT & PKT_HEARTBEAT_ACK (16 bytes) */
typedef struct PS5T_PACKED {
    ps5t_header_t hdr;
    uint32_t      timestamp_ms;   /* Echoed back in ACK for RTT measurement */
    uint8_t       transport_mode; /* ps5t_transport_t */
    uint8_t       status_flags;   /* STATUS_* (used on ACK, 0 on request) */
    uint16_t      reserved;       /* Must be 0 */
} ps5t_pkt_heartbeat_t;

/* Compile-time layout guarantees matching Protocol.swift byte-for-byte */
#ifdef __cplusplus
static_assert(sizeof(ps5t_header_t) == 8, "ps5t_header_t must be 8 bytes");
static_assert(sizeof(ps5t_pkt_discover_t) == 28, "ps5t_pkt_discover_t must be 28 bytes");
static_assert(sizeof(ps5t_pkt_discover_ack_t) == 16, "ps5t_pkt_discover_ack_t must be 16 bytes");
static_assert(sizeof(ps5t_pkt_roi_frame_hdr_t) == 40, "ps5t_pkt_roi_frame_hdr_t must be 40 bytes");
static_assert(sizeof(ps5t_pkt_translation_hdr_t) == 20, "ps5t_pkt_translation_hdr_t must be 20 bytes");
static_assert(sizeof(ps5t_pkt_heartbeat_t) == 16, "ps5t_pkt_heartbeat_t must be 16 bytes");
#else
_Static_assert(sizeof(ps5t_header_t) == 8, "ps5t_header_t must be 8 bytes");
_Static_assert(sizeof(ps5t_pkt_discover_t) == 28, "ps5t_pkt_discover_t must be 28 bytes");
_Static_assert(sizeof(ps5t_pkt_discover_ack_t) == 16, "ps5t_pkt_discover_ack_t must be 16 bytes");
_Static_assert(sizeof(ps5t_pkt_roi_frame_hdr_t) == 40, "ps5t_pkt_roi_frame_hdr_t must be 40 bytes");
_Static_assert(sizeof(ps5t_pkt_translation_hdr_t) == 20, "ps5t_pkt_translation_hdr_t must be 20 bytes");
_Static_assert(sizeof(ps5t_pkt_heartbeat_t) == 16, "ps5t_pkt_heartbeat_t must be 16 bytes");
#endif

#ifdef __cplusplus
}
#endif

#endif /* PS5_TRANSLATOR_PROTOCOL_H */
