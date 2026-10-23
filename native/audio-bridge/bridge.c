#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
#define _DARWIN_C_SOURCE /* MSG_DONTWAIT for the host test build */
#endif
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

/* The MU5250 helper calls these four interposable symbols with PCM16 buffers.
 * The agent pins the inspected helper's SHA-256 before enabling this adapter;
 * a firmware change requires rechecking the ABI, direction, and sample format.
 * The inherited socket is private to this child and never carries IP traffic. */
static int audio_fd = -1;
static pthread_rwlock_t lifecycle = PTHREAD_RWLOCK_INITIALIZER;
enum { MAX_PCM = 8192, HEADER = 8, KEEP = 4 };
/* Phone audio waiting for the modem. The helper takes one frame per 20 ms, so frames queued
 * beyond KEEP (80 ms) are late audio: the oldest are dropped instead of delaying the call. */
static pthread_mutex_t held_lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned char held[KEEP][MAX_PCM];
static int held_first, held_count;

static int packet(int fd, unsigned char kind, const void *data, unsigned int size) {
    if (size > MAX_PCM) return -EMSGSIZE;
    unsigned char bytes[HEADER + MAX_PCM] = {'O', 'U', '6', '0', kind, 0, size & 255, size >> 8};
    if (size) memcpy(bytes + HEADER, data, size);
    ssize_t count = send(fd, bytes, HEADER + size, 0);
    return count == (ssize_t)(HEADER + size) ? (int)size : -(count < 0 ? errno : EIO);
}

int zte_rtp_init(void) {
    pthread_rwlock_wrlock(&lifecycle);
    if (audio_fd >= 0) { pthread_rwlock_unlock(&lifecycle); return 0; }
    const char *value = getenv("OPENU60_AUDIO_FD");
    char *end = NULL;
    long fd = value ? strtol(value, &end, 10) : -1;
    if (!value || !*value || *end || fd < 3 || fd > 65535) {
        pthread_rwlock_unlock(&lifecycle); return -EINVAL;
    }
    int owned = dup((int)fd);
    if (owned < 0) { int error = errno; pthread_rwlock_unlock(&lifecycle); return -error; }
    struct timeval timeout = { .tv_sec = 2, .tv_usec = 0 };
    if (setsockopt(owned, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0 ||
        setsockopt(owned, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) < 0) {
        int error = errno; close(owned); pthread_rwlock_unlock(&lifecycle); return -error;
    }
    const unsigned char format[8] = {0x40, 0x1f, 0, 0, 1, 0, 16, 0}; /* 8 kHz, mono, PCM16LE */
    int result = packet(owned, 1, format, sizeof(format));
    if (result < 0) close(owned); else audio_fd = owned;
    pthread_rwlock_unlock(&lifecycle);
    return result < 0 ? result : 0;
}

int zte_rtp_dsp_send_handler(const void *pcm, unsigned short size) {
    if (!pcm || !size || size > MAX_PCM || size % 2) return -EINVAL;
    pthread_rwlock_rdlock(&lifecycle);
    int result = audio_fd < 0 ? -ENOTCONN : packet(audio_fd, 2, pcm, size);
    pthread_rwlock_unlock(&lifecycle);
    return result;
}

/* One uplink frame of exactly `capacity` bytes into `pcm`, or -EAGAIN when none is queued
 * and `flags` asks not to wait. */
static int take(int fd, int flags, void *pcm, unsigned int capacity) {
    unsigned char bytes[HEADER + MAX_PCM + 1];
    ssize_t count = recv(fd, bytes, sizeof(bytes), flags);
    if (count < 0) return errno == EWOULDBLOCK ? -EAGAIN : -errno;
    if (count < HEADER || memcmp(bytes, "OU60", 4) || bytes[4] != 3 || bytes[5] != 0) return -EPROTO;
    unsigned int size = bytes[6] | ((unsigned int)bytes[7] << 8);
    if (size != capacity || count != (ssize_t)(size + HEADER)) return -EMSGSIZE;
    memcpy(pcm, bytes + HEADER, size);
    return (int)size;
}

int zte_rtp_dsp_receive_handler(void *pcm, unsigned int capacity) {
    if (!pcm || !capacity || capacity > MAX_PCM || capacity % 2) return -EINVAL;
    pthread_rwlock_rdlock(&lifecycle);
    if (audio_fd < 0) { pthread_rwlock_unlock(&lifecycle); return -ENOTCONN; }
    pthread_mutex_lock(&held_lock);
    int result = 0;
    unsigned char frame[MAX_PCM];
    while ((result = take(audio_fd, MSG_DONTWAIT, frame, capacity)) > 0) {
        if (held_count == KEEP) { held_first = (held_first + 1) % KEEP; held_count--; }
        memcpy(held[(held_first + held_count) % KEEP], frame, capacity);
        held_count++;
    }
    if (result == -EAGAIN) {
        if (held_count) {
            memcpy(pcm, held[held_first], capacity);
            held_first = (held_first + 1) % KEEP; held_count--;
            result = (int)capacity;
        } else {
            result = take(audio_fd, 0, frame, capacity);
            if (result > 0) memcpy(pcm, frame, capacity);
        }
    }
    pthread_mutex_unlock(&held_lock);
    pthread_rwlock_unlock(&lifecycle);
    return result;
}

void zte_rtp_deinit(void) {
    pthread_rwlock_wrlock(&lifecycle);
    if (audio_fd >= 0) { close(audio_fd); audio_fd = -1; }
    pthread_mutex_lock(&held_lock); held_first = held_count = 0; pthread_mutex_unlock(&held_lock);
    pthread_rwlock_unlock(&lifecycle);
}
