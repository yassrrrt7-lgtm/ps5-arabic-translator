#include "plugin_common.h"

#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

/* Pre-allocated static buffers -> ZERO heap allocations during gameplay */
static int      s_sock_fd = -1;
static uint8_t  s_tx_buf[PS5T_MAX_UDP_PACKET];
static uint8_t  s_rx_buf[2048];

static struct sockaddr_in s_lan_addr;
static struct sockaddr_in s_wifi_addr;
static struct sockaddr_in s_bcast_addr;

static bool     s_wifi_discovered = false;
static uint8_t  s_current_transport = TRANSPORT_UNKNOWN;
static uint64_t s_last_ack_ms = 0;
static uint64_t s_last_hb_sent_ms = 0;
static uint64_t s_last_disc_sent_ms = 0;
static uint32_t s_discover_nonce = 0x13572468U;

static void fill_sockaddr(struct sockaddr_in* out, const char* ip, uint16_t port) {
    memset(out, 0, sizeof(*out));
    out->sin_family = AF_INET;
    out->sin_port = htons(port);
    inet_pton(AF_INET, ip, &out->sin_addr);
}

static bool get_active_target(uint8_t net_pref, struct sockaddr_in* out_addr, uint8_t* out_transport) {
    if (net_pref == NET_PREF_LAN) {
        *out_addr = s_lan_addr;
        *out_transport = TRANSPORT_LAN;
        return true;
    }
    if (net_pref == NET_PREF_WIFI) {
        if (!s_wifi_discovered) return false;
        *out_addr = s_wifi_addr;
        *out_transport = TRANSPORT_WIFI;
        return true;
    }

    /* NET_PREF_AUTO: prioritize Direct LAN; failover to discovered Wi-Fi if LAN is silent */
    if (s_current_transport == TRANSPORT_WIFI && s_wifi_discovered) {
        *out_addr = s_wifi_addr;
        *out_transport = TRANSPORT_WIFI;
        return true;
    }
    *out_addr = s_lan_addr;
    *out_transport = TRANSPORT_LAN;
    return true;
}

extern "C" bool net_init(void) {
    net_shutdown();

    s_sock_fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s_sock_fd < 0) {
        return false;
    }

    int yes = 1;
    setsockopt(s_sock_fd, SOL_SOCKET, SO_BROADCAST, &yes, sizeof(yes));
    setsockopt(s_sock_fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    int sndbuf = 131072;
    int rcvbuf = 131072;
    setsockopt(s_sock_fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
    setsockopt(s_sock_fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

    int flags = fcntl(s_sock_fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(s_sock_fd, F_SETFL, flags | O_NONBLOCK);
    }

    struct sockaddr_in bind_addr;
    memset(&bind_addr, 0, sizeof(bind_addr));
    bind_addr.sin_family = AF_INET;
    bind_addr.sin_port = htons(0); /* Ephemeral local port */
    bind_addr.sin_addr.s_addr = htonl(INADDR_ANY);
    bind(s_sock_fd, (struct sockaddr*)&bind_addr, sizeof(bind_addr));

    fill_sockaddr(&s_lan_addr, PS5T_LAN_IPHONE_IP, PS5T_PORT_DATA);
    fill_sockaddr(&s_bcast_addr, "255.255.255.255", PS5T_PORT_DISCOVERY);
    memset(&s_wifi_addr, 0, sizeof(s_wifi_addr));

    s_wifi_discovered = false;
    s_current_transport = TRANSPORT_LAN;
    s_last_ack_ms = 0;
    s_last_hb_sent_ms = 0;
    s_last_disc_sent_ms = 0;
    return true;
}

extern "C" void net_shutdown(void) {
    if (s_sock_fd >= 0) {
        close(s_sock_fd);
        s_sock_fd = -1;
    }
    s_wifi_discovered = false;
    s_current_transport = TRANSPORT_UNKNOWN;
}

static void send_heartbeat_to(const struct sockaddr_in* target, uint8_t transport_hint, uint64_t now) {
    ps5t_pkt_heartbeat_t hb;
    memset(&hb, 0, sizeof(hb));
    hb.hdr.magic       = PS5T_MAGIC;
    hb.hdr.version     = PS5T_PROTOCOL_VERSION;
    hb.hdr.type        = PKT_HEARTBEAT;
    hb.hdr.payload_len = (uint16_t)(sizeof(hb) - sizeof(ps5t_header_t));
    hb.timestamp_ms    = (uint32_t)(now & 0xFFFFFFFFU);
    hb.transport_mode  = transport_hint;
    hb.status_flags    = 0;

    sendto(s_sock_fd, &hb, sizeof(hb), 0, (const struct sockaddr*)target, sizeof(*target));
}

static void send_discovery_broadcast(const ps5t_runtime_t* rt) {
    ps5t_pkt_discover_t disc;
    memset(&disc, 0, sizeof(disc));
    disc.hdr.magic       = PS5T_MAGIC;
    disc.hdr.version     = PS5T_PROTOCOL_VERSION;
    disc.hdr.type        = PKT_DISCOVER;
    disc.hdr.payload_len = (uint16_t)(sizeof(disc) - sizeof(ps5t_header_t));
    disc.client_nonce    = ++s_discover_nonce;
    memcpy(disc.title_id, rt->title_id, PS5T_TITLE_ID_LEN);

    sendto(s_sock_fd, &disc, sizeof(disc), 0, (const struct sockaddr*)&s_bcast_addr, sizeof(s_bcast_addr));
}

extern "C" void net_tick(ps5t_runtime_t* rt) {
    if (!rt || s_sock_fd < 0) return;

    uint64_t now = ps5t_now_ms();
    uint8_t pref = rt->cfg.net_pref;

    /* 1. Periodic heartbeat every 500ms */
    if ((now - s_last_hb_sent_ms) >= PS5T_HEARTBEAT_INTERVAL_MS) {
        s_last_hb_sent_ms = now;

        /* In AUTO mode, always probe Direct LAN so plugging Ethernet back switches instantly */
        if (pref == NET_PREF_AUTO || pref == NET_PREF_LAN) {
            send_heartbeat_to(&s_lan_addr, TRANSPORT_LAN, now);
        }
        if ((pref == NET_PREF_AUTO || pref == NET_PREF_WIFI) && s_wifi_discovered) {
            send_heartbeat_to(&s_wifi_addr, TRANSPORT_WIFI, now);
        }
    }

    /* 2. Auto-failover: if no heartbeat ACK within 1000ms, broadcast Wi-Fi discovery */
    bool timed_out = (s_last_ack_ms == 0) || ((now - s_last_ack_ms) >= PS5T_FAILOVER_TIMEOUT_MS);
    if (timed_out) {
        rt->display.active_transport = TRANSPORT_UNKNOWN;
        if (pref != NET_PREF_LAN && (now - s_last_disc_sent_ms) >= 1000) {
            s_last_disc_sent_ms = now;
            send_discovery_broadcast(rt);
        }
    }
}

extern "C" void net_poll_incoming(ps5t_runtime_t* rt) {
    if (!rt || s_sock_fd < 0) return;

    uint64_t now = ps5t_now_ms();

    for (int iter = 0; iter < 32; ++iter) {
        struct sockaddr_in from_addr;
        socklen_t from_len = sizeof(from_addr);
        ssize_t n = recvfrom(s_sock_fd, s_rx_buf, sizeof(s_rx_buf), 0,
                             (struct sockaddr*)&from_addr, &from_len);
        if (n <= 0) {
            break;
        }
        if ((size_t)n < sizeof(ps5t_header_t)) {
            continue;
        }

        ps5t_header_t hdr;
        memcpy(&hdr, s_rx_buf, sizeof(hdr));
        if (hdr.magic != PS5T_MAGIC || hdr.version != PS5T_PROTOCOL_VERSION) {
            continue;
        }
        if ((size_t)n < sizeof(ps5t_header_t) + hdr.payload_len) {
            continue;
        }

        if (hdr.type == PKT_DISCOVER_ACK && (size_t)n >= sizeof(ps5t_pkt_discover_ack_t)) {
            ps5t_pkt_discover_ack_t ack;
            memcpy(&ack, s_rx_buf, sizeof(ack));
            if (ack.transport_hint == TRANSPORT_LAN) {
                s_lan_addr.sin_addr = from_addr.sin_addr;
                s_lan_addr.sin_port = htons(ack.data_port);
                s_current_transport = TRANSPORT_LAN;
            } else {
                s_wifi_addr = from_addr;
                s_wifi_addr.sin_port = htons(ack.data_port);
                s_wifi_discovered = true;
                if (rt->cfg.net_pref != NET_PREF_LAN) {
                    s_current_transport = TRANSPORT_WIFI;
                }
            }
            s_last_ack_ms = now;
            rt->display.active_transport = s_current_transport;
            rt->display.server_ready = ack.server_ready;
        } else if (hdr.type == PKT_HEARTBEAT_ACK && (size_t)n >= sizeof(ps5t_pkt_heartbeat_t)) {
            ps5t_pkt_heartbeat_t ack;
            memcpy(&ack, s_rx_buf, sizeof(ack));
            s_last_ack_ms = now;

            /* LAN always takes priority in AUTO mode when alive */
            if (ack.transport_mode == TRANSPORT_LAN && rt->cfg.net_pref != NET_PREF_WIFI) {
                s_current_transport = TRANSPORT_LAN;
            } else if (ack.transport_mode == TRANSPORT_WIFI && rt->cfg.net_pref != NET_PREF_LAN) {
                s_wifi_addr = from_addr;
                s_wifi_addr.sin_port = htons(PS5T_PORT_DATA);
                s_wifi_discovered = true;
                if (s_current_transport != TRANSPORT_LAN) {
                    s_current_transport = TRANSPORT_WIFI;
                }
            }

            rt->display.active_transport = s_current_transport;
            rt->display.server_ready = (ack.status_flags & STATUS_MODEL_READY) ? 1 : 0;
            rt->display.thermal_warn = (ack.status_flags & STATUS_THERMAL_WARN) ? 1 : 0;
        } else if (hdr.type == PKT_TRANSLATION_STREAM && (size_t)n >= sizeof(ps5t_pkt_translation_hdr_t)) {
            ps5t_pkt_translation_hdr_t thdr;
            memcpy(&thdr, s_rx_buf, sizeof(thdr));

            if (thdr.utf8_byte_length > PS5T_MAX_UTF8_BYTES) continue;
            if ((size_t)n < sizeof(ps5t_pkt_translation_hdr_t) + thdr.utf8_byte_length) continue;

            /* Ignore stale frames or out-of-order older stream chunks */
            if (thdr.frame_id < rt->display.last_frame_id) continue;
            if (thdr.frame_id == rt->display.last_frame_id && thdr.seq_num < rt->display.last_seq_num) continue;

            /* Double-buffer swap: write into back buffer, then publish index atomically */
            int next_idx = 1 - rt->display.active_idx;
            if (thdr.flags & TRANS_FLAG_CLEAR) {
                rt->display.utf8_buf[next_idx][0] = '\0';
                rt->display.is_clear = 1;
            } else {
                memcpy(rt->display.utf8_buf[next_idx],
                       s_rx_buf + sizeof(ps5t_pkt_translation_hdr_t),
                       thdr.utf8_byte_length);
                rt->display.utf8_buf[next_idx][thdr.utf8_byte_length] = '\0';
                rt->display.is_clear = 0;
            }

            __sync_synchronize();
            rt->display.active_idx      = next_idx;
            rt->display.last_frame_id   = thdr.frame_id;
            rt->display.last_seq_num    = thdr.seq_num;
            rt->display.last_latency_ms = thdr.latency_ms;
            rt->display.is_cache_hit    = (thdr.flags & TRANS_FLAG_CACHE_HIT) ? 1 : 0;
            s_last_ack_ms = now;
        }
    }
}

extern "C" bool net_send_roi_frame(
    ps5t_runtime_t* rt,
    uint32_t frame_id,
    const uint8_t* gray_pixels,
    uint16_t width,
    uint16_t height,
    uint8_t flags
) {
    if (!rt || !gray_pixels || s_sock_fd < 0) return false;

    uint32_t total_bytes = (uint32_t)width * (uint32_t)height;
    if (total_bytes == 0 || total_bytes > PS5T_MAX_ROI_BYTES) {
        return false;
    }

    struct sockaddr_in target;
    uint8_t transport = TRANSPORT_UNKNOWN;
    if (!get_active_target(rt->cfg.net_pref, &target, &transport)) {
        return false;
    }

    uint32_t total_chunks = (total_bytes + PS5T_MAX_CHUNK_DATA - 1U) / PS5T_MAX_CHUNK_DATA;
    if (total_chunks == 0 || total_chunks > PS5T_MAX_CHUNKS) {
        return false;
    }

    for (uint32_t c = 0; c < total_chunks; ++c) {
        uint32_t offset = c * PS5T_MAX_CHUNK_DATA;
        uint32_t remain = total_bytes - offset;
        uint16_t chunk_len = (uint16_t)(remain > PS5T_MAX_CHUNK_DATA ? PS5T_MAX_CHUNK_DATA : remain);

        ps5t_pkt_roi_frame_hdr_t pkt_hdr;
        memset(&pkt_hdr, 0, sizeof(pkt_hdr));
        pkt_hdr.hdr.magic       = PS5T_MAGIC;
        pkt_hdr.hdr.version     = PS5T_PROTOCOL_VERSION;
        pkt_hdr.hdr.type        = PKT_ROI_FRAME;
        pkt_hdr.hdr.payload_len = (uint16_t)((sizeof(pkt_hdr) - sizeof(ps5t_header_t)) + chunk_len);
        pkt_hdr.frame_id        = frame_id;
        memcpy(pkt_hdr.title_id, rt->title_id, PS5T_TITLE_ID_LEN);
        pkt_hdr.width           = width;
        pkt_hdr.height          = height;
        pkt_hdr.pixel_format    = PIXFMT_GRAY8;
        pkt_hdr.chunk_index     = (uint8_t)c;
        pkt_hdr.total_chunks    = (uint8_t)total_chunks;
        pkt_hdr.flags           = flags;
        pkt_hdr.chunk_bytes     = chunk_len;

        memcpy(s_tx_buf, &pkt_hdr, sizeof(pkt_hdr));
        memcpy(s_tx_buf + sizeof(pkt_hdr), gray_pixels + offset, chunk_len);

        sendto(s_sock_fd, s_tx_buf, sizeof(pkt_hdr) + chunk_len, 0,
               (const struct sockaddr*)&target, sizeof(target));
    }

    return true;
}
