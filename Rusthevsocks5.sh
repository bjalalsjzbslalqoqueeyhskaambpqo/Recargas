#include <jni.h>
#include <android/multinetwork.h>
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/timerfd.h>
#include <sys/socket.h>
#include <sys/resource.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>
#include <poll.h>
#include <fcntl.h>
#include <signal.h>
#include <netdb.h>

#ifndef TCP_QUICKACK
#define TCP_QUICKACK 12
#endif

#ifndef TCP_USER_TIMEOUT
#define TCP_USER_TIMEOUT 18
#endif

#define OP_PING        0x10
#define OP_PONG        0x11
#define OP_STRM_OPEN   0x12
#define OP_STRM_DATA   0x13
#define OP_STRM_CLOSE  0x14
#define OP_SYNC_STATE  0x15
#define OP_SYNC_RST    0x16
#define OP_KICK        0x18
#define OP_EXPIRED     0x19

#define FRAME_HDR         8
#define MAX_PAYLOAD       32768
#define KEEPALIVE_SEC     5
#define HANDSHAKE_TIMEOUT 4000
#define EPOLL_BATCH_SIZE  256
#define MAX_STREAM_BUF    1048576

#define PROXY_HOST_V6  "emailmarketing.personal.com.ar"
#define TUNNEL_HOST_V6 "2.brawlpass.com.ar"
#define PROXY_HOST_V4  "recarga.personal.com.ar"
#define TUNNEL_HOST_V4 "dif2pyjxd7k7p.cloudfront.net"
#define PROXY_PORT     80
#define CONNECT_MS     2000

static const char *PROXY_IPS_V6[] = { "2606:4700::6812:16b7", "2606:4700::6812:17b7" };

static struct {
    atomic_int run; atomic_int sid_seq; char iid[160];
    pthread_mutex_t mu; JavaVM *jvm; jobject svc; net_handle_t net; pthread_t thr;
    jclass cb_c, pr_c; jmethodID cb_m, pr_m;
    int tfd, efd, wfd;
    atomic_int gaming_mode;
} g = { .mu = PTHREAD_MUTEX_INITIALIZER, .tfd = -1, .efd = -1, .wfd = -1 };

typedef struct st_node {
    struct st_node *next;
    uint32_t sid; int cfd;
    int pending; int paused;
    uint8_t *buf; size_t off, len, cap;
} st_node;

#define ST_SIZE 4096
#define ST_MASK (ST_SIZE - 1)
static st_node *g_st[ST_SIZE];

static struct {
    uint8_t *buf; size_t off, len, cap; int blocked;
    int r_st; size_t r_hlen, r_plen; uint16_t r_exp;
    uint8_t r_hdr[FRAME_HDR], r_pay[MAX_PAYLOAD];
    int missed_pings; uint32_t rtt_us;
} tun;

static __thread JNIEnv *t_env = NULL;
static __thread int t_att = 0;

static JNIEnv *jni_get(void) {
    if (t_env) return t_env;
    JavaVM *vm; pthread_mutex_lock(&g.mu); vm = g.jvm; pthread_mutex_unlock(&g.mu);
    if (!vm) return NULL;
    if ((*vm)->GetEnv(vm, (void **)&t_env, JNI_VERSION_1_6) == JNI_OK) { t_att = 0; return t_env; }
    if ((*vm)->AttachCurrentThread(vm, &t_env, NULL) == JNI_OK) { t_att = 1; return t_env; }
    return NULL;
}

static void jni_release(void) {
    if (!t_att || !t_env) return;
    JavaVM *vm; pthread_mutex_lock(&g.mu); vm = g.jvm; pthread_mutex_unlock(&g.mu);
    if (vm) (*vm)->DetachCurrentThread(vm);
    t_env = NULL; t_att = 0;
}

static void push_event(const char *ev) {
    jclass cls; jmethodID mid;
    pthread_mutex_lock(&g.mu); cls = g.cb_c; mid = g.cb_m; pthread_mutex_unlock(&g.mu);
    if (!cls || !mid) return;
    JNIEnv *e = jni_get(); if (!e) return;
    jstring js = (*e)->NewStringUTF(e, ev);
    if (js) { (*e)->CallStaticVoidMethod(e, cls, mid, js); (*e)->DeleteLocalRef(e, js); }
    if ((*e)->ExceptionCheck(e)) (*e)->ExceptionClear(e);
}

static void push_tunnel_latency(int fd) {
#ifdef TCP_INFO
    struct tcp_info info;
    socklen_t len = sizeof(info);
    if (fd < 0 || getsockopt(fd, IPPROTO_TCP, TCP_INFO, &info, &len) != 0) return;
    unsigned int rtt_us = info.tcpi_rtt;
    if (!rtt_us) return;
    tun.rtt_us = rtt_us;
    char ev[32];
    snprintf(ev, sizeof(ev), "ping:%u", (rtt_us + 500U) / 1000U);
    push_event(ev);
#else
    (void)fd;
#endif
}

static int buf_append(uint8_t **b, size_t *off, size_t *len, size_t *cap, const uint8_t *d, size_t dl) {
    if (!dl) return 0;
    if (*off + *len + dl > *cap) {
        if (*len && *off) memmove(*b, *b + *off, *len);
        *off = 0;
        if (*len + dl > *cap) {
            size_t nc = (*len + dl) * 2 + 8192;
            uint8_t *nb = realloc(*b, nc);
            if (!nb) return -1;
            *b = nb; *cap = nc;
        }
    }
    memcpy(*b + *off + *len, d, dl); *len += dl;
    return 0;
}

static void buf_consume(uint8_t **b, size_t *off, size_t *len, size_t *cap, size_t amt) {
    if (amt >= *len) {
        *off = 0; *len = 0;
        if (*cap > 65536) { free(*b); *b = NULL; *cap = 0; }
    } else {
        *off += amt; *len -= amt;
    }
}

static void st_init(void) {
    memset(g_st, 0, sizeof(g_st)); free(tun.buf); memset(&tun, 0, sizeof(tun));
    tun.missed_pings = 0; tun.rtt_us = 0;
}

static st_node *st_get(uint32_t sid) {
    for (st_node *n = g_st[sid & ST_MASK]; n; n = n->next) if (n->sid == sid) return n;
    return NULL;
}

static st_node *st_put(uint32_t sid, int cfd) {
    st_node *n = calloc(1, sizeof(*n)); if (!n) return NULL;
    n->sid = sid; n->cfd = cfd; n->pending = 1; n->paused = 0;
    int sl = sid & ST_MASK; n->next = g_st[sl]; g_st[sl] = n;
    return n;
}

static void epoll_set(int epfd, int op, int fd, uint32_t ev, uint64_t data) {
    struct epoll_event e = {ev, {.u64 = data}}; epoll_ctl(epfd, op, fd, &e);
}

static void st_pause(int epfd, st_node *n) {
    if (n->paused) return;
    n->paused = 1;
    uint32_t evs = EPOLLRDHUP | EPOLLOUT;
    epoll_set(epfd, EPOLL_CTL_MOD, n->cfd, evs, (uint64_t)n->sid<<32 | n->cfd);
}

static void st_resume(int epfd, st_node *n) {
    if (!n->paused) return;
    n->paused = 0;
    uint32_t evs = EPOLLRDHUP | EPOLLIN;
    epoll_set(epfd, EPOLL_CTL_MOD, n->cfd, evs, (uint64_t)n->sid<<32 | n->cfd);
}

static void tun_update_epoll(int epfd, int tfd) {
    uint32_t evs = EPOLLIN | EPOLLRDHUP; if (tun.len > 0) evs |= EPOLLOUT;
    epoll_set(epfd, EPOLL_CTL_MOD, tfd, evs, tfd);
}

static void toggle_bp(int epfd, int blocked) {
    for (int i = 0; i < ST_SIZE; i++)
        for (st_node *n = g_st[i]; n; n = n->next) {
            if (n->paused) continue;
            uint32_t evs = EPOLLRDHUP;
            if (!blocked) evs |= EPOLLIN;
            if (n->len > 0) evs |= EPOLLOUT;
            epoll_set(epfd, EPOLL_CTL_MOD, n->cfd, evs, (uint64_t)n->sid<<32 | n->cfd);
        }
}

static int tun_send_v(int epfd, int tfd, uint8_t op, uint8_t flags, uint32_t sid, const uint8_t *data, uint16_t dlen) {
    uint8_t hdr[FRAME_HDR] = { op, flags, sid>>24, sid>>16, sid>>8, sid, dlen>>8, dlen };
    if (!tun.len && !tun.blocked) {
        struct iovec iov[2] = { {hdr, FRAME_HDR}, {(void*)data, dlen} };
        ssize_t n;
        do { n = writev(tfd, iov, dlen ? 2 : 1); } while (n < 0 && errno == EINTR);
        size_t tot = FRAME_HDR + dlen, sent = (n > 0) ? n : 0;
        if (n == (ssize_t)tot) return 0;
        if (sent < FRAME_HDR) {
            if (buf_append(&tun.buf, &tun.off, &tun.len, &tun.cap, hdr + sent, FRAME_HDR - sent) < 0) return -1;
            if (dlen && buf_append(&tun.buf, &tun.off, &tun.len, &tun.cap, data, dlen) < 0) return -1;
        } else {
            if (buf_append(&tun.buf, &tun.off, &tun.len, &tun.cap, data + (sent - FRAME_HDR), tot - sent) < 0) return -1;
        }
        tun.blocked = 1; toggle_bp(epfd, 1); tun_update_epoll(epfd, tfd);
        return 0;
    }
    if (buf_append(&tun.buf, &tun.off, &tun.len, &tun.cap, hdr, FRAME_HDR) < 0) return -1;
    if (dlen && buf_append(&tun.buf, &tun.off, &tun.len, &tun.cap, data, dlen) < 0) return -1;
    return 0;
}

static void tun_flush(int epfd, int tfd) {
    if (!tun.len) return;
    ssize_t n;
    do { n = send(tfd, tun.buf + tun.off, tun.len, MSG_NOSIGNAL | MSG_DONTWAIT); } while (n < 0 && errno == EINTR);
    if (n > 0) {
        buf_consume(&tun.buf, &tun.off, &tun.len, &tun.cap, n);
        if (!tun.len) {
            if (tun.blocked) { tun.blocked = 0; toggle_bp(epfd, 0); }
            tun_update_epoll(epfd, tfd);
        }
    }
}

static void st_close(int epfd, int tfd, uint32_t sid, st_node *st, int notify) {
    if (!st) st = st_get(sid); if (!st) return;
    epoll_ctl(epfd, EPOLL_CTL_DEL, st->cfd, NULL);
    shutdown(st->cfd, SHUT_RDWR); close(st->cfd);
    if (notify) tun_send_v(epfd, tfd, OP_STRM_CLOSE, 0, sid, NULL, 0);
    st_node **pp = &g_st[sid & ST_MASK];
    while (*pp) { if ((*pp)->sid == sid) { st_node *n = *pp; *pp = n->next; free(n->buf); free(n); return; } pp = &(*pp)->next; }
}

static int st_flush(int epfd, int tfd, st_node *st) {
    if (!st->len) return 0;
    ssize_t n;
    do { n = send(st->cfd, st->buf + st->off, st->len, MSG_NOSIGNAL | MSG_DONTWAIT); } while (n < 0 && errno == EINTR);
    if (n > 0) {
        buf_consume(&st->buf, &st->off, &st->len, &st->cap, n);
        if (!st->len) st_resume(epfd, st);
    } else if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
        st_close(epfd, tfd, st->sid, st, 1); return -1;
    }
    return 0;
}

static void protect_fd(int fd) {
    pthread_mutex_lock(&g.mu); net_handle_t net = g.net; jclass cls = g.pr_c; jmethodID mid = g.pr_m; jobject svc = g.svc; pthread_mutex_unlock(&g.mu);
    if (net != NETWORK_UNSPECIFIED) android_setsocknetwork(net, fd);
    if (!cls || !mid) return;
    JNIEnv *e = jni_get(); if (!e) return;
    if (svc) { (*e)->CallBooleanMethod(e, svc, mid, fd); if ((*e)->ExceptionCheck(e)) (*e)->ExceptionClear(e); }
}

static int make_sock(int af) {
    int fd = socket(af, SOCK_STREAM, 0); if (fd < 0) return -1;
    protect_fd(fd);

    int gaming = atomic_load(&g.gaming_mode);
    if (gaming) {
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        setsockopt(fd, IPPROTO_TCP, TCP_QUICKACK, &one, sizeof(one));
        int timeout = 15000;
        setsockopt(fd, IPPROTO_TCP, TCP_USER_TIMEOUT, &timeout, sizeof(timeout));
        int v = 15;
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &v, sizeof(v));
        v = 5; setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &v, sizeof(v));
        v = 3; setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &v, sizeof(v));
    } else {
        int zero = 0;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &zero, sizeof(zero));
        int timeout = 60000;
        setsockopt(fd, IPPROTO_TCP, TCP_USER_TIMEOUT, &timeout, sizeof(timeout));
        int one = 1, v = 60;
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &v, sizeof(v));
        v = 15; setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &v, sizeof(v));
        v = 4; setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &v, sizeof(v));
        int sndbuf = 131072;
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
        int rcvbuf = 131072;
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    }

    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    return fd;
}

static int try_connect(int af, struct sockaddr *sa, socklen_t sl, int ms) {
    int fd = make_sock(af); if (fd < 0) return -1;
    if (connect(fd, sa, sl) != 0 && errno != EINPROGRESS) { close(fd); return -1; }
    struct pollfd p = {fd, POLLOUT, 0}; int e = 0; socklen_t el = sizeof(e);
    if (poll(&p, 1, ms) <= 0 || getsockopt(fd, SOL_SOCKET, SO_ERROR, &e, &el) < 0 || e) { close(fd); return -1; }
    return fd;
}

static int recv_headers(int fd, char *buf, int cap, int ms) {
    for (int u = 0; u < cap - 1;) {
        struct pollfd p = {fd, POLLIN, 0}; if (poll(&p, 1, ms) <= 0) break;
        ssize_t n; do { n = recv(fd, buf + u, cap - 1 - u, 0); } while (n < 0 && errno == EINTR);
        if (n > 0) { u += n; buf[u] = 0; if (strstr(buf, "\r\n\r\n")) return u; continue; }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) continue; break;
    }
    return -1;
}

static void get_hdr(const char *h, const char *k, char *out, size_t cap) {
    out[0] = 0; size_t kl = strlen(k);
    for (const char *p = h; *p;) {
        const char *eol = strstr(p, "\r\n"); size_t len = eol ? (size_t)(eol - p) : strlen(p);
        if (len >= kl && strncasecmp(p, k, kl) == 0) {
            const char *v = p + kl; while (*v == ' ' || *v == '\t') v++;
            size_t vl = len - (size_t)(v - p); if (vl >= cap) vl = cap - 1;
            memcpy(out, v, vl); out[vl] = 0; return;
        }
        if (!eol) break; p = eol + 2;
    }
}

static int do_handshake(int fd, const char *ph, const char *th) {
    char buf[16384];
    int n = snprintf(buf, sizeof(buf), "HEAD http://%s HTTP/1.1\r\nHost: %s\r\n\r\n", ph, ph);
    send(fd, buf, n, MSG_NOSIGNAL);
    if (recv_headers(fd, buf, sizeof(buf), HANDSHAKE_TIMEOUT) < 0) return -1;

    int gaming = atomic_load(&g.gaming_mode);
    const char *action = gaming ? "tunnel-gaming" : "tunnel";

    n = snprintf(buf, sizeof(buf), "PACHTS http://%s HTTP/1.1\r\nHost: %s\r\n\r\nGET htt://%s HTTP/1.1\r\nHost: %s\r\nAction: %s\r\nX-Internal-ID: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n", ph, ph, th, th, action, g.iid[0] ? g.iid : "unknown");
    send(fd, buf, n, MSG_NOSIGNAL); usleep(800000);

    char h[16384] = {0}; int code = -1;
    for (int u = 0; u < (int)sizeof(h) - 1;) {
        struct pollfd p = {fd, POLLIN, 0}; if (poll(&p, 1, HANDSHAKE_TIMEOUT) <= 0) break;
        ssize_t nr; do { nr = recv(fd, h + u, sizeof(h) - 1 - u, 0); } while (nr < 0 && errno == EINTR);
        if (nr > 0) {
            u += nr; h[u] = 0;
            const char *last = h, *ptr = h;
            while ((ptr = strstr(ptr, "HTTP/")) != NULL) { last = ptr; ptr += 5; }
            if (strstr(last, "\r\n\r\n") && sscanf(last, "HTTP/%*d.%*d %d", &code) == 1 && code != 200) break;
            continue;
        }
        if (nr < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) continue; break;
    }

    if (code >= 500 && code < 600) { push_event("service_unavailable"); return -1; }
    if (code == 401 || code == 403 || code == 410) {
        char r[64] = {0}, ev[96]; get_hdr(h, "X-Disconnect-Reason:", r, sizeof(r));
        if (r[0]) { snprintf(ev, sizeof(ev), "disconnect_reason:%s", r); push_event(ev); }
        push_event("auth_rejected"); return -2;
    }
    if (code != 101) return -1;

    char ws[32] = {0}; get_hdr(h, "X-Wait-Status:", ws, sizeof(ws));
    if (ws[0]) {
        char ev[64], tmp[1024]; snprintf(ev, sizeof(ev), "waiting_status:%s", ws); push_event(ev);
        if (strstr(h, "activated")) { push_event("wait_activated"); return -2; }
        while (atomic_load(&g.run)) { struct pollfd p = {fd, POLLIN, 0}; if (poll(&p, 1, 1000) <= 0) continue; ssize_t nr = recv(fd, tmp, sizeof(tmp)-1, 0); if (nr <= 0) break; tmp[nr] = 0; if (strstr(tmp, "activated")) { push_event("wait_activated"); return -2; } }
        return -2;
    }
    char un[128]={0}, us[32]={0}, ud[32]={0}, ev[160];
    get_hdr(h, "X-User-Name:", un, sizeof(un)); get_hdr(h, "X-User-Secs:", us, sizeof(us)); get_hdr(h, "X-User-Days:", ud, sizeof(ud));
    if (un[0]) { snprintf(ev, sizeof(ev), "user_name:%s", un); push_event(ev); }
    if (us[0]) { snprintf(ev, sizeof(ev), "user_secs:%s", us); push_event(ev); } else if (ud[0]) { snprintf(ev, sizeof(ev), "user_days:%s", ud); push_event(ev); }
    push_event("tunnel_ready"); return 0;
}

static int open_tunnel(void) {
    push_event("connecting");
    for (int i = 0; i < (int)(sizeof(PROXY_IPS_V6)/sizeof(*PROXY_IPS_V6)); i++) {
        struct sockaddr_in6 a = {0}; a.sin6_family = AF_INET6; a.sin6_port = htons(PROXY_PORT);
        if (inet_pton(AF_INET6, PROXY_IPS_V6[i], &a.sin6_addr) != 1) continue;
        int fd = try_connect(AF_INET6, (struct sockaddr *)&a, sizeof(a), 300); if (fd < 0) continue;
        int r = do_handshake(fd, PROXY_HOST_V6, TUNNEL_HOST_V6); if (r == 0) return fd;
        close(fd); if (r == -2) return -2;
    }
    struct addrinfo hints = {.ai_family=AF_INET, .ai_socktype=SOCK_STREAM}, *res = NULL;
    char port[8]; snprintf(port, sizeof(port), "%d", PROXY_PORT);
    if (getaddrinfo(PROXY_HOST_V4, port, &hints, &res) != 0) return -1;
    int fd = -1; for (struct addrinfo *c = res; c && fd < 0; c = c->ai_next) fd = try_connect(AF_INET, c->ai_addr, c->ai_addrlen, CONNECT_MS);
    freeaddrinfo(res); if (fd < 0) return -1;
    int r = do_handshake(fd, PROXY_HOST_V4, TUNNEL_HOST_V4); if (r < 0) { close(fd); return r; } return fd;
}

static int make_relay(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0), one = 1; if (fd < 0) return -1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    struct sockaddr_in la = {.sin_family=AF_INET, .sin_port=htons(port), .sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    if (bind(fd, (struct sockaddr *)&la, sizeof(la)) < 0 || listen(fd, SOMAXCONN) < 0) { close(fd); return -1; }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK); return fd;
}

static int handle_tun_rx(int epfd, int tfd) {
    while (1) {
        if (!tun.r_st) {
            ssize_t n; do { n = recv(tfd, tun.r_hdr + tun.r_hlen, FRAME_HDR - tun.r_hlen, 0); } while (n < 0 && errno == EINTR);
            if (n <= 0) return (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK));
            if ((tun.r_hlen += n) == FRAME_HDR) {
                tun.r_st = 1; tun.r_plen = 0; tun.r_exp = (tun.r_hdr[6] << 8) | tun.r_hdr[7];
                if (tun.r_exp > MAX_PAYLOAD) return 1;
            }
        } else {
            if (tun.r_exp) {
                ssize_t n; do { n = recv(tfd, tun.r_pay + tun.r_plen, tun.r_exp - tun.r_plen, 0); } while (n < 0 && errno == EINTR);
                if (n <= 0) return (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK));
                tun.r_plen += n;
            }
            if (tun.r_plen == tun.r_exp) {
                uint8_t op = tun.r_hdr[0];
                uint32_t sid = ((uint32_t)tun.r_hdr[2]<<24) | ((uint32_t)tun.r_hdr[3]<<16) | ((uint32_t)tun.r_hdr[4]<<8) | tun.r_hdr[5];
                st_node *st = st_get(sid);

                if (op == OP_STRM_DATA && st && tun.r_exp) {
                    if (!st->len) {
                        ssize_t ns; do { ns = send(st->cfd, tun.r_pay, tun.r_exp, MSG_NOSIGNAL | MSG_DONTWAIT); } while (ns < 0 && errno == EINTR);
                        size_t sent = (ns > 0) ? ns : 0;
                        if (sent < tun.r_exp) {
                            if (buf_append(&st->buf, &st->off, &st->len, &st->cap, tun.r_pay + sent, tun.r_exp - sent) < 0 || st->len > MAX_STREAM_BUF) {
                                st_close(epfd, tfd, sid, st, 1);
                            } else {
                                st_pause(epfd, st);
                            }
                        }
                    } else {
                        if (buf_append(&st->buf, &st->off, &st->len, &st->cap, tun.r_pay, tun.r_exp) < 0 || st->len > MAX_STREAM_BUF) {
                            st_close(epfd, tfd, sid, st, 1);
                        }
                    }
                } else if (op == OP_STRM_DATA && !st) {
                    tun_send_v(epfd, tfd, OP_SYNC_RST, 0, sid, NULL, 0);
                } else if (op == OP_STRM_CLOSE || op == OP_SYNC_RST) {
                    if (st) st_close(epfd, tfd, sid, st, 0);
                } else if (op == OP_PING) {
                    tun_send_v(epfd, tfd, OP_PONG, 0, 0, NULL, 0);
                } else if (op == OP_PONG) {
                } else if (op == OP_KICK || op == OP_EXPIRED) {
                    if (op == OP_EXPIRED) push_event("auth_rejected");
                    push_event("reconnect_required"); return 1;
                } else if (op != OP_STRM_OPEN && op != OP_SYNC_STATE) {
                    return 1;
                }
                tun.r_st = tun.r_hlen = 0;
            }
        }
    }
    return 0;
}

static void handle_stream_rx(int epfd, int tfd, uint32_t sid, st_node *st) {
    int gaming = atomic_load(&g.gaming_mode);
    size_t chunk = gaming ? 4096 : MAX_PAYLOAD;
    if (tun.rtt_us > 200000) chunk = 16384;
    if (tun.rtt_us > 400000) chunk = 8192;
    if (tun.rtt_us > 800000) chunk = 4096;
    if (chunk > MAX_PAYLOAD) chunk = MAX_PAYLOAD;

    uint8_t buf[MAX_PAYLOAD];

    while (!tun.blocked) {
        ssize_t nr; do { nr = recv(st->cfd, buf, chunk, 0); } while (nr < 0 && errno == EINTR);
        if (nr > 0) {
            if (tun_send_v(epfd, tfd, OP_STRM_DATA, 0, sid, buf, (uint16_t)nr) < 0) {
                st_close(epfd, tfd, sid, st, 1); break;
            }
            if (nr < (ssize_t)chunk) break;
        } else {
            if (nr == 0 || (errno != EAGAIN && errno != EWOULDBLOCK))
                st_close(epfd, tfd, sid, st, 1);
            break;
        }
    }
}

static void handle_accept(int epfd, int tfd, int rfd) {
    while (1) {
        struct sockaddr_in ca; socklen_t cl = sizeof(ca);
        int cfd = accept4(rfd, (struct sockaddr *)&ca, &cl, SOCK_NONBLOCK | SOCK_CLOEXEC);
        if (cfd < 0) {
            if (errno == EINTR || errno == ECONNABORTED) continue;
            break;
        }

        int gaming = atomic_load(&g.gaming_mode);
        if (gaming) {
            int one = 1;
            setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            setsockopt(cfd, IPPROTO_TCP, TCP_QUICKACK, &one, sizeof(one));
        }

        uint32_t sid;
        do { sid = (uint32_t)atomic_fetch_add(&g.sid_seq, 1) & 0x7FFFFFFF; } while (!sid || st_get(sid));

        st_node *st = st_put(sid, cfd);
        if (!st) { close(cfd); continue; }

        if (tun_send_v(epfd, tfd, OP_STRM_OPEN, 0, sid, NULL, 0) < 0) {
            st_close(epfd, tfd, sid, st, 0); continue;
        }

        epoll_set(epfd, EPOLL_CTL_ADD, cfd, EPOLLIN | EPOLLRDHUP, (uint64_t)sid<<32 | cfd);
    }
}

static void *main_thread(void *arg) {
    int port = (int)(intptr_t)arg; signal(SIGPIPE, SIG_IGN); jni_get();
    while (atomic_load(&g.run)) {
        int tfd = open_tunnel(); if (tfd < 0) { if (!atomic_load(&g.run) || tfd == -2) break; sleep(3); continue; }
        int rfd = make_relay(port); if (rfd < 0) { close(tfd); sleep(2); continue; }
        int wakefd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
        int timerfd = timerfd_create(CLOCK_BOOTTIME, TFD_NONBLOCK | TFD_CLOEXEC);
        if (timerfd < 0) timerfd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
        int epfd = epoll_create1(EPOLL_CLOEXEC);
        if (epfd < 0 || wakefd < 0 || timerfd < 0) { if (epfd >= 0) close(epfd); if (timerfd >= 0) close(timerfd); if (wakefd >= 0) close(wakefd); close(rfd); close(tfd); sleep(1); continue; }
        struct itimerspec its = { .it_interval={KEEPALIVE_SEC,0}, .it_value={KEEPALIVE_SEC,0} }; timerfd_settime(timerfd, 0, &its, NULL);
        epoll_set(epfd, EPOLL_CTL_ADD, rfd, EPOLLIN, rfd);
        epoll_set(epfd, EPOLL_CTL_ADD, wakefd, EPOLLIN, wakefd);
        epoll_set(epfd, EPOLL_CTL_ADD, timerfd, EPOLLIN, timerfd);
        epoll_set(epfd, EPOLL_CTL_ADD, tfd, EPOLLIN | EPOLLRDHUP, tfd);
        pthread_mutex_lock(&g.mu); g.tfd = tfd; g.efd = epfd; g.wfd = wakefd; pthread_mutex_unlock(&g.mu);
        st_init(); push_event("connected"); push_tunnel_latency(tfd);
        struct epoll_event evs[EPOLL_BATCH_SIZE]; int dead = 0; int tick_counter = 0;

        while (atomic_load(&g.run) && !dead) {
            int n = epoll_wait(epfd, evs, EPOLL_BATCH_SIZE, -1); if (n < 0) { if (errno == EINTR) continue; break; }
            for (int i = 0; i < n && !dead; i++) {
                uint64_t edata = evs[i].data.u64; uint32_t evm = evs[i].events; int efd = (int)(uint32_t)edata;
                if (efd == wakefd) { dead = 1; break; }
                if (efd == timerfd) {
                    uint64_t exp; read(timerfd, &exp, sizeof(exp));
                    if (exp > 1) tun.missed_pings = 0; else tun.missed_pings++;
                    if (tun.missed_pings >= 3) { dead = 1; continue; }
                    tun_send_v(epfd, tfd, OP_PING, 0, 0, NULL, 0);
                    push_tunnel_latency(tfd);
                    tick_counter += exp;
                    if (tick_counter >= 3) {
                        tick_counter = 0;
                        uint8_t payload[32760]; uint16_t count = 0;
                        for (int k = 0; k < ST_SIZE; k++) {
                            for (st_node *n = g_st[k]; n; n = n->next) {
                                if (count >= 8190) break;
                                payload[count*4] = n->sid >> 24; payload[count*4+1] = n->sid >> 16;
                                payload[count*4+2] = n->sid >> 8; payload[count*4+3] = n->sid; count++;
                            }
                        }
                        tun_send_v(epfd, tfd, OP_SYNC_STATE, 0, 0, payload, count * 4);
                    }
                    continue;
                }
                if (efd == tfd) {
                    if (evm & EPOLLOUT) tun_flush(epfd, tfd);
                    if (evm & EPOLLIN) {
                        tun.missed_pings = 0;
                        dead = handle_tun_rx(epfd, tfd);
                    }
                    if (!dead && (evm & (EPOLLHUP|EPOLLERR|EPOLLRDHUP))) dead = 1;
                    continue;
                }
                if (efd == rfd) { handle_accept(epfd, tfd, rfd); continue; }

                uint32_t sid = (uint32_t)(edata >> 32); st_node *st = st_get(sid); if (!st) continue;
                if (evm & EPOLLOUT) { if (st_flush(epfd, tfd, st) < 0) continue; }
                if ((evm & EPOLLIN) && !tun.blocked && !st->paused) handle_stream_rx(epfd, tfd, sid, st);
                if ((evm & (EPOLLHUP|EPOLLERR|EPOLLRDHUP)) && st_get(sid)) st_close(epfd, tfd, sid, st, 1);
            }
        }

        push_event("disconnected");
        pthread_mutex_lock(&g.mu); g.tfd = g.efd = g.wfd = -1; pthread_mutex_unlock(&g.mu);
        for (int i = 0; i < ST_SIZE; i++) while (g_st[i]) { st_node *nd = g_st[i]; shutdown(nd->cfd, SHUT_RDWR); close(nd->cfd); g_st[i] = nd->next; free(nd->buf); free(nd); }
        free(tun.buf); tun.buf = NULL;
        close(epfd); close(timerfd); close(wakefd); close(rfd); shutdown(tfd, SHUT_RDWR); close(tfd);
        if (atomic_load(&g.run)) sleep(3);
    }
    jni_release(); return NULL;
}

JNIEXPORT jint JNICALL n_start(JNIEnv *env, jclass clazz, jint port, jobject svc, jstring iid) {
    (void)clazz; pthread_mutex_lock(&g.mu); int already = atomic_load(&g.run); pthread_t ot = g.thr; pthread_mutex_unlock(&g.mu);
    if (already) return 0; if (ot) { pthread_join(ot, NULL); pthread_mutex_lock(&g.mu); g.thr = 0; pthread_mutex_unlock(&g.mu); }
    pthread_mutex_lock(&g.mu); (*env)->GetJavaVM(env, &g.jvm); g.svc = (*env)->NewGlobalRef(env, svc); g.iid[0] = 0;
    if (iid) { const char *s = (*env)->GetStringUTFChars(env, iid, NULL); if (s) { snprintf(g.iid, sizeof(g.iid), "%s", s); (*env)->ReleaseStringUTFChars(env, iid, s); } }
    jclass pc = (*env)->GetObjectClass(env, svc); if (pc) { g.pr_c = (*env)->NewGlobalRef(env, pc); g.pr_m = (*env)->GetMethodID(env, pc, "protect", "(I)Z"); (*env)->DeleteLocalRef(env, pc); }
    atomic_store(&g.run, 1); atomic_init(&g.sid_seq, 1); pthread_mutex_unlock(&g.mu); pthread_t thr;
    if (pthread_create(&thr, NULL, main_thread, (void *)(intptr_t)port) != 0) { pthread_mutex_lock(&g.mu); atomic_store(&g.run, 0); (*env)->DeleteGlobalRef(env, g.svc); g.svc = NULL; g.jvm = NULL; pthread_mutex_unlock(&g.mu); return -1; }
    pthread_mutex_lock(&g.mu); g.thr = thr; pthread_mutex_unlock(&g.mu); return 0;
}

JNIEXPORT void JNICALL n_stop(JNIEnv *env, jclass clazz) {
    (void)clazz; pthread_mutex_lock(&g.mu); if (!atomic_load(&g.run) && !g.thr) { pthread_mutex_unlock(&g.mu); return; }
    pthread_t th = g.thr; g.thr = 0; atomic_store(&g.run, 0); g.iid[0] = 0; jobject svc = g.svc; g.svc = NULL; g.jvm = NULL; int ww = g.wfd; pthread_mutex_unlock(&g.mu);
    if (ww >= 0) { uint64_t v = 1; write(ww, &v, 8); } if (th) pthread_join(th, NULL);
    pthread_mutex_lock(&g.mu); int epfd = g.efd, tfd = g.tfd, wfd = g.wfd; g.efd = g.tfd = g.wfd = -1; pthread_mutex_unlock(&g.mu);
    if (epfd >= 0) close(epfd); if (tfd >= 0) { shutdown(tfd, SHUT_RDWR); close(tfd); } if (wfd >= 0) close(wfd);
    if (g.pr_c) { (*env)->DeleteGlobalRef(env, g.pr_c); g.pr_c = NULL; } g.pr_m = NULL; if (svc) (*env)->DeleteGlobalRef(env, svc);
}

JNIEXPORT void JNICALL n_net(JNIEnv *e, jclass c, jlong net) {
    (void)e; (void)c;
    pthread_mutex_lock(&g.mu); net_handle_t old_net = g.net; g.net = (net_handle_t)net; int ww = g.wfd; pthread_mutex_unlock(&g.mu);
    if (old_net != (net_handle_t)net && ww >= 0) { uint64_t v = 1; write(ww, &v, 8); }
}

JNIEXPORT jstring JNICALL n_status(JNIEnv *env, jclass c) {
    (void)c; char buf[64];
    snprintf(buf, sizeof(buf), "%s\n0", atomic_load(&g.run) && g.tfd >= 0 ? "connected" : "disconnected");
    return (*env)->NewStringUTF(env, buf);
}

JNIEXPORT void JNICALL n_set_gaming(JNIEnv *e, jclass c, jboolean is_gaming) {
    (void)e; (void)c;
    atomic_store(&g.gaming_mode, is_gaming ? 1 : 0);
}

static JNINativeMethod g_m[] = {
    {"nativeStart",      "(ILandroid/net/VpnService;Ljava/lang/String;)I", (void *)n_start},
    {"nativeStop",       "()V",                                             (void *)n_stop},
    {"nativeSetNetwork", "(J)V",                                            (void *)n_net},
    {"nativeGetStatus",  "()Ljava/lang/String;",                            (void *)n_status},
    {"nativeSetGamingMode", "(Z)V",                                         (void *)n_set_gaming}
};

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *r) {
    (void)r; JNIEnv *env = NULL; if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
    jclass cls = (*env)->FindClass(env, "com/blacktunnel/BtProxy"); if (!cls) return JNI_ERR;
    if ((*env)->RegisterNatives(env, cls, g_m, sizeof(g_m)/sizeof(*g_m)) < 0) return JNI_ERR;
    jmethodID cb = (*env)->GetStaticMethodID(env, cls, "onNativeEvent", "(Ljava/lang/String;)V"); if (!cb) return JNI_ERR;
    pthread_mutex_lock(&g.mu); g.cb_c = (*env)->NewGlobalRef(env, cls); g.cb_m = cb; pthread_mutex_unlock(&g.mu);
    (*env)->DeleteLocalRef(env, cls); return JNI_VERSION_1_6;
}
