#ifndef TXRING_H
#define TXRING_H
#include <stdint.h>

/* Lock-free single-producer ring buffer for realtime audio.
   Producer: the CoreAudio input callback.
   Consumers: tx_ring_copy_latest (non-consuming snapshot for analysis) and
              tx_ring_read (consuming FIFO read for the monitor output). */
typedef struct TXRing TXRing;

TXRing  *tx_ring_create(uint32_t capacity);          /* rounded up to power of two */
void     tx_ring_destroy(TXRing *r);
void     tx_ring_reset(TXRing *r);                    /* only while the producer is stopped */
void     tx_ring_write(TXRing *r, const float *src, uint32_t n);
uint64_t tx_ring_total_written(TXRing *r);
int      tx_ring_copy_latest(TXRing *r, float *dst, uint32_t n);   /* 1 = ok, 0 = not enough data */
uint32_t tx_ring_read(TXRing *r, float *dst, uint32_t n);          /* returns frames read */
uint32_t tx_ring_readable(TXRing *r);
void     tx_ring_trim(TXRing *r, uint32_t maxReadable);            /* consumer: drop old data to bound latency */

#endif
