#include "TXRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct TXRing {
    float *data;
    uint32_t capacity;
    uint32_t mask;
    _Atomic uint64_t w;
    _Atomic uint64_t r;
};

TXRing *tx_ring_create(uint32_t capacity) {
    uint32_t c = 1;
    while (c < capacity) c <<= 1;
    TXRing *rb = calloc(1, sizeof(TXRing));
    if (!rb) return NULL;
    rb->data = calloc(c, sizeof(float));
    if (!rb->data) { free(rb); return NULL; }
    rb->capacity = c;
    rb->mask = c - 1;
    atomic_init(&rb->w, 0);
    atomic_init(&rb->r, 0);
    return rb;
}

void tx_ring_destroy(TXRing *rb) {
    if (!rb) return;
    free(rb->data);
    free(rb);
}

void tx_ring_reset(TXRing *rb) {
    atomic_store(&rb->w, 0);
    atomic_store(&rb->r, 0);
}

static void copy_in(TXRing *rb, uint64_t pos, const float *src, uint32_t n) {
    uint32_t start = (uint32_t)(pos & rb->mask);
    uint32_t first = rb->capacity - start;
    if (first > n) first = n;
    memcpy(rb->data + start, src, first * sizeof(float));
    if (n > first) memcpy(rb->data, src + first, (n - first) * sizeof(float));
}

static void copy_out(TXRing *rb, uint64_t pos, float *dst, uint32_t n) {
    uint32_t start = (uint32_t)(pos & rb->mask);
    uint32_t first = rb->capacity - start;
    if (first > n) first = n;
    memcpy(dst, rb->data + start, first * sizeof(float));
    if (n > first) memcpy(dst + first, rb->data, (n - first) * sizeof(float));
}

void tx_ring_write(TXRing *rb, const float *src, uint32_t n) {
    uint64_t w = atomic_load_explicit(&rb->w, memory_order_relaxed);
    uint64_t advance = n;
    if (n > rb->capacity) { src += n - rb->capacity; w += n - rb->capacity; n = rb->capacity; }
    copy_in(rb, w, src, n);
    atomic_store_explicit(&rb->w, atomic_load_explicit(&rb->w, memory_order_relaxed) + advance,
                          memory_order_release);
}

uint64_t tx_ring_total_written(TXRing *rb) {
    return atomic_load_explicit(&rb->w, memory_order_acquire);
}

int tx_ring_copy_latest(TXRing *rb, float *dst, uint32_t n) {
    if (n > rb->capacity) return 0;
    uint64_t w = atomic_load_explicit(&rb->w, memory_order_acquire);
    if (w < n) return 0;
    copy_out(rb, w - n, dst, n);
    return 1;
}

uint32_t tx_ring_readable(TXRing *rb) {
    uint64_t w = atomic_load_explicit(&rb->w, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&rb->r, memory_order_relaxed);
    uint64_t a = w > r ? w - r : 0;
    return a > rb->capacity ? rb->capacity : (uint32_t)a;
}

void tx_ring_trim(TXRing *rb, uint32_t maxReadable) {
    uint64_t w = atomic_load_explicit(&rb->w, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&rb->r, memory_order_relaxed);
    if (w > r && w - r > maxReadable)
        atomic_store_explicit(&rb->r, w - maxReadable, memory_order_release);
}

uint32_t tx_ring_read(TXRing *rb, float *dst, uint32_t n) {
    uint64_t w = atomic_load_explicit(&rb->w, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&rb->r, memory_order_relaxed);
    if (r > w) r = w;                                   /* after reset */
    if (w - r > rb->capacity) r = w - rb->capacity / 2; /* overrun: skip ahead */
    uint64_t avail = w - r;
    if (n > avail) n = (uint32_t)avail;
    if (n) copy_out(rb, r, dst, n);
    atomic_store_explicit(&rb->r, r + n, memory_order_release);
    return n;
}
