//! Lock-free SPSC PCM ring. The realtime capture callback (producer) must
//! never block; overflow increments a dropped-sample counter instead.

use rtrb::{Consumer, Producer, RingBuffer};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

/// Максимальный размер одной выгрузки PCM в DSP за один тик.
///
/// Ограничение сохраняет liveness: producer может продолжать писать в ring,
/// но consumer всё равно возвращается к VAD/координатору и проверке stop.
pub const DRAIN_BATCH_SAMPLES: usize = 4_096;

pub struct PcmProducer {
    inner: Producer<i16>,
    dropped: Arc<AtomicU64>,
}

pub struct PcmConsumer {
    inner: Consumer<i16>,
    dropped: Arc<AtomicU64>,
}

/// Create a single-producer/single-consumer i16 ring with `capacity_samples`.
pub fn pcm_ring(capacity_samples: usize) -> (PcmProducer, PcmConsumer) {
    let (p, c) = RingBuffer::<i16>::new(capacity_samples.max(64));
    let dropped = Arc::new(AtomicU64::new(0));
    (
        PcmProducer {
            inner: p,
            dropped: dropped.clone(),
        },
        PcmConsumer { inner: c, dropped },
    )
}

impl PcmProducer {
    /// Push as many samples as fit; the rest are dropped (counted). Never blocks.
    pub fn push_samples(&mut self, samples: &[i16]) {
        let mut overflow = 0u64;
        for &s in samples {
            if self.inner.push(s).is_err() {
                overflow += 1;
            }
        }
        if overflow > 0 {
            self.dropped.fetch_add(overflow, Ordering::Relaxed);
        }
    }

    pub fn dropped(&self) -> u64 {
        self.dropped.load(Ordering::Relaxed)
    }
}

impl PcmConsumer {
    /// Выгрузить не более [`DRAIN_BATCH_SAMPLES`] доступных сэмплов в `out`.
    ///
    /// Producer может продолжать запись параллельно; bounded batch не даёт
    /// realtime DSP застрять внутри drain при постоянном потоке данных.
    pub fn drain_into(&mut self, out: &mut Vec<i16>) {
        for _ in 0..DRAIN_BATCH_SAMPLES {
            let Ok(s) = self.inner.pop() else { break };
            out.push(s);
        }
    }

    pub fn dropped(&self) -> u64 {
        self.dropped.load(Ordering::Relaxed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicBool;
    use std::sync::atomic::Ordering as AtomicOrdering;

    #[test]
    fn push_then_drain() {
        let (mut p, mut c) = pcm_ring(1024);
        p.push_samples(&[1, 2, 3, 4]);
        let mut out = Vec::new();
        c.drain_into(&mut out);
        assert_eq!(out, vec![1, 2, 3, 4]);
        assert_eq!(p.dropped(), 0);
    }

    #[test]
    fn overflow_is_counted_not_blocking() {
        let (mut p, _c) = pcm_ring(64); // min capacity
        p.push_samples(&vec![7i16; 10_000]);
        assert!(p.dropped() > 0);
    }

    #[test]
    fn drain_batch_is_bounded_while_producer_continues() {
        let (mut p, mut c) = pcm_ring(DRAIN_BATCH_SAMPLES * 4);
        p.push_samples(&vec![1_i16; DRAIN_BATCH_SAMPLES * 2]);

        let keep_writing = Arc::new(AtomicBool::new(true));
        let producer_flag = keep_writing.clone();
        let producer = std::thread::spawn(move || {
            let block = [1_i16; 256];
            while producer_flag.load(AtomicOrdering::Relaxed) {
                p.push_samples(&block);
            }
        });

        let mut out = Vec::new();
        c.drain_into(&mut out);
        keep_writing.store(false, AtomicOrdering::Relaxed);
        producer.join().expect("producer thread");

        assert_eq!(out.len(), DRAIN_BATCH_SAMPLES);
    }
}
