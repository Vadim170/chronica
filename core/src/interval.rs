//! Interval cut coordinator — decides when to slice the continuous audio into
//! transcription intervals. OWNER: module agent. Port 1:1 from the legacy
//! `IntervalCutCoordinator` (Python), with the new defaults.
//!
//! Rules (all times in seconds; `mono` is a monotonic clock supplied by the
//! pipeline, wall-clock via chrono::Local):
//! - Track per-channel silence. "all_silent" = every registered channel silent.
//! - elapsed = mono_now - interval_start_mono.
//! - elapsed >= max_interval_s  -> force cut now.
//! - elapsed <  min_interval_s  -> only track silence start, never cut.
//! - min <= elapsed < max: if all_silent continuously for >= silence_cut_ms,
//!   cut at the MIDDLE of the gap (silence_start + silence_cut_ms/2000/2 sec)
//!   so the boundary falls between words. Any speech resets the silence timer.
//! - On cut: sample_offset = round(elapsed_from_start * 16000); the next
//!   interval starts at the cut wall-clock time.
//! - flush_current: on stop, cut the remainder unless it is < 0.5s.

use std::collections::BTreeMap;

use chrono::{DateTime, Duration, Local};

use crate::audio::resample::TARGET_SAMPLE_RATE;

#[derive(Clone, Debug)]
pub struct CutPoint {
    /// Offset (in 16kHz samples) from the interval start where to split.
    pub sample_offset: usize,
    pub start_at: DateTime<Local>,
    pub end_at: DateTime<Local>,
}

#[derive(Clone, Debug)]
pub struct CurrentInterval {
    pub start_at: DateTime<Local>,
    pub elapsed_s: f64,
    pub all_silent: bool,
}

pub struct IntervalCutCoordinator {
    min_interval_s: f64,
    max_interval_s: f64,
    silence_cut_ms: f64,

    interval_start_mono: f64,
    interval_start_dt: DateTime<Local>,

    /// Insertion-ordered not required — semantics only need "all silent".
    channel_silence: BTreeMap<String, bool>,
    silence_start_mono: Option<f64>,

    cut_requested: bool,
    cut_at_sample_offset: Option<usize>,
    cut_at_dt: Option<DateTime<Local>>,
    /// Монотонное время самого реза (не момента, когда его забрали).
    ///
    /// Рез по тишине ставится в СЕРЕДИНУ паузы, то есть в прошлое относительно
    /// текущего кадра. Следующий интервал обязан начинаться именно отсюда:
    /// иначе монотонная и настенная шкалы расходятся на `silence_cut_ms/2` за
    /// каждый рез (длительности занижены), а соответствующий кусок аудио
    /// навсегда остаётся в буфере канала и никогда не транскрибируется.
    cut_at_mono: Option<f64>,
}

impl IntervalCutCoordinator {
    pub fn new(min_interval_s: f64, max_interval_s: f64, silence_cut_ms: f64) -> Self {
        Self::new_at(
            min_interval_s,
            max_interval_s,
            silence_cut_ms,
            0.0,
            Local::now(),
        )
    }

    /// Test-friendly constructor that fixes the initial monotonic time and
    /// wall-clock start. Production code uses `new` (mono base 0.0 — the
    /// pipeline supplies absolute monotonic timestamps consistently).
    fn new_at(
        min_interval_s: f64,
        max_interval_s: f64,
        silence_cut_ms: f64,
        start_mono: f64,
        start_dt: DateTime<Local>,
    ) -> Self {
        Self {
            min_interval_s,
            max_interval_s,
            silence_cut_ms,
            interval_start_mono: start_mono,
            interval_start_dt: start_dt,
            channel_silence: BTreeMap::new(),
            silence_start_mono: None,
            cut_requested: false,
            cut_at_sample_offset: None,
            cut_at_dt: None,
            cut_at_mono: None,
        }
    }

    pub fn register_channel(&mut self, role: &str) {
        self.channel_silence.insert(role.to_string(), true);
    }

    /// Горячее обновление параметров нарезки во время записи.
    ///
    /// Координатор создаётся один раз на старте; этот метод даёт DSP-потоку
    /// менять длину интервала и порог тишины на лету (значения перечитываются
    /// из общего `RuntimeParams`). Позиция текущего интервала
    /// (`interval_start_mono`/`_dt`) не сбрасывается; накопленный таймер тишины
    /// сохраняется, если новый минимум всё ещё допускает его, и очищается
    /// только при увеличении минимума за уже наблюденный момент тишины.
    pub fn set_params(&mut self, min_interval_s: f64, max_interval_s: f64, silence_cut_ms: f64) {
        // A hot increase of the minimum can make an already-running silence
        // timer ineligible.  Drop that timer; it will start again at the first
        // silent frame after the new minimum.  Keep it when only the silence
        // threshold changes so a live adjustment remains continuous.
        let min_changed = (self.min_interval_s - min_interval_s).abs() > f64::EPSILON;
        self.min_interval_s = min_interval_s;
        self.max_interval_s = max_interval_s;
        self.silence_cut_ms = silence_cut_ms;
        if min_changed
            && self
                .silence_start_mono
                .is_some_and(|start| start < self.interval_start_mono + self.min_interval_s)
        {
            self.silence_start_mono = None;
        }
    }

    fn all_silent(&self) -> bool {
        if self.channel_silence.is_empty() {
            false
        } else {
            self.channel_silence.values().all(|&s| s)
        }
    }

    /// Report one channel's silence state at monotonic time `frame_mono`.
    pub fn report_silence(&mut self, role: &str, is_silent: bool, frame_mono: f64) {
        if self.cut_requested {
            return;
        }
        self.channel_silence.insert(role.to_string(), is_silent);
        let elapsed = frame_mono - self.interval_start_mono;
        let all_silent = self.all_silent();

        // Force cut at max_interval.
        if elapsed >= self.max_interval_s {
            self.trigger_cut(frame_mono);
            return;
        }

        if elapsed < self.min_interval_s {
            // Silence observed before the minimum is deliberately not timed:
            // carrying it across the boundary would place the cut before
            // `min_interval_s` (for example a 30s interval became ~1s after a
            // long silent start).  Start timing on the first eligible frame.
            self.silence_start_mono = None;
            return;
        }

        // Between min and max: wait for a silence gap.
        if all_silent {
            match self.silence_start_mono {
                None => self.silence_start_mono = Some(frame_mono),
                Some(start) => {
                    let silence_duration_ms = (frame_mono - start) * 1000.0;
                    if silence_duration_ms >= self.silence_cut_ms {
                        // Cut at the center of the silence gap.
                        // Clamp defensively: a stale timer or a hot parameter
                        // change must never create a non-forced sub-minimum
                        // interval (nor move its boundary past max).
                        let min_cut = self.interval_start_mono + self.min_interval_s;
                        let max_cut = self.interval_start_mono + self.max_interval_s;
                        let cut_mono =
                            (start + (self.silence_cut_ms / 2000.0)).clamp(min_cut, max_cut);
                        self.trigger_cut(cut_mono);
                    }
                }
            }
        } else {
            self.silence_start_mono = None;
        }
    }

    fn trigger_cut(&mut self, cut_mono_time: f64) {
        self.cut_requested = true;
        let elapsed_from_start = cut_mono_time - self.interval_start_mono;
        self.cut_at_sample_offset =
            Some((elapsed_from_start * TARGET_SAMPLE_RATE as f64).round() as usize);
        self.cut_at_dt = Some(self.interval_start_dt + secs_to_duration(elapsed_from_start));
        self.cut_at_mono = Some(cut_mono_time);
    }

    /// Returns a pending cut (and advances to the next interval) if one is due.
    ///
    /// `_mono_now` больше не участвует в расчёте границы (её задаёт сам рез —
    /// см. `cut_at_mono`), но остаётся в сигнатуре: вызывающий код всё равно
    /// передаёт единое монотонное «сейчас» во все методы координатора.
    pub fn check_cut(&mut self, _mono_now: f64) -> Option<CutPoint> {
        if !self.cut_requested {
            return None;
        }
        let sample_offset = self.cut_at_sample_offset.expect("cut offset set");
        let start_at = self.interval_start_dt;
        let cut_dt = self.cut_at_dt.expect("cut dt set");
        let cut_mono = self.cut_at_mono.expect("cut mono set");

        // Reset for the next interval — start at the cut point on BOTH шкалах.
        // `mono_now` здесь был бы ошибкой: он позже реза (рез стоит в середине
        // паузы, и забирают его следующим тиком), а `cut_dt` — ровно в резе.
        self.cut_requested = false;
        self.interval_start_mono = cut_mono;
        self.interval_start_dt = cut_dt;
        self.silence_start_mono = None;
        self.cut_at_sample_offset = None;
        self.cut_at_dt = None;
        self.cut_at_mono = None;

        Some(CutPoint {
            sample_offset,
            start_at,
            end_at: cut_dt,
        })
    }

    pub fn current_interval_info(&self, mono_now: f64) -> CurrentInterval {
        let elapsed = mono_now - self.interval_start_mono;
        CurrentInterval {
            start_at: self.interval_start_dt,
            // Mirror Python's round(elapsed, 1).
            elapsed_s: (elapsed * 10.0).round() / 10.0,
            all_silent: self.all_silent(),
        }
    }

    /// Force-cut remainder on stop (None if < 0.5s).
    pub fn flush_current(&mut self, mono_now: f64) -> Option<CutPoint> {
        let elapsed = mono_now - self.interval_start_mono;
        if elapsed < 0.5 {
            return None;
        }
        let sample_offset = (elapsed * TARGET_SAMPLE_RATE as f64).round() as usize;
        let cut_dt = self.interval_start_dt + secs_to_duration(elapsed);
        Some(CutPoint {
            sample_offset,
            start_at: self.interval_start_dt,
            end_at: cut_dt,
        })
    }
}

/// Convert fractional seconds into a chrono Duration without losing sub-second
/// precision (mirrors Python's `timedelta(seconds=...)`).
fn secs_to_duration(secs: f64) -> Duration {
    let nanos = (secs * 1_000_000_000.0).round() as i64;
    Duration::nanoseconds(nanos)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    const MIN: f64 = 300.0;
    const MAX: f64 = 600.0;
    const SILENCE_MS: f64 = 2000.0;

    fn base_dt() -> DateTime<Local> {
        Local.with_ymd_and_hms(2026, 6, 18, 12, 0, 0).unwrap()
    }

    fn coord() -> IntervalCutCoordinator {
        IntervalCutCoordinator::new_at(MIN, MAX, SILENCE_MS, 0.0, base_dt())
    }

    fn coord_one_channel() -> IntervalCutCoordinator {
        let mut c = coord();
        c.register_channel("mic");
        c
    }

    #[test]
    fn force_cut_at_max_interval() {
        let mut c = coord_one_channel();
        // Speech the whole time — only max should force the cut.
        c.report_silence("mic", false, 100.0);
        assert!(c.check_cut(100.0).is_none());

        // Exactly at max -> cut now.
        c.report_silence("mic", false, MAX);
        let cut = c.check_cut(MAX).expect("cut at max");
        assert_eq!(cut.sample_offset, (MAX * 16000.0).round() as usize);
        assert_eq!(cut.start_at, base_dt());
        assert_eq!(cut.end_at, base_dt() + Duration::seconds(600));
    }

    #[test]
    fn no_cut_before_min_even_when_silent() {
        let mut c = coord_one_channel();
        // Long continuous silence but still before min_interval.
        c.report_silence("mic", true, 10.0);
        c.report_silence("mic", true, 50.0);
        c.report_silence("mic", true, 100.0); // 90s of silence, < 300 min
        assert!(c.check_cut(100.0).is_none());
        assert!(!c.cut_requested);
    }

    #[test]
    fn continuous_silence_crossing_min_starts_timer_at_min() {
        let mut c = IntervalCutCoordinator::new_at(30.0, 300.0, 2_000.0, 0.0, base_dt());
        c.register_channel("mic");

        // Silence before the minimum must not be carried into the eligible
        // window: otherwise the old implementation cut at ~1s.
        c.report_silence("mic", true, 0.0);
        c.report_silence("mic", true, 29.99);
        c.report_silence("mic", true, 30.0);
        assert!(c.check_cut(30.0).is_none());
        c.report_silence("mic", true, 31.99);
        assert!(c.check_cut(31.99).is_none());

        c.report_silence("mic", true, 32.01);
        let cut = c.check_cut(32.01).expect("cut after eligible silence gap");
        let duration_s = (cut.end_at - cut.start_at).num_milliseconds() as f64 / 1000.0;
        assert!(
            duration_s >= 30.0,
            "non-forced silence cut must respect min, got {duration_s}s"
        );
        assert!(duration_s <= 300.0);
    }

    #[test]
    fn increasing_minimum_discards_ineligible_silence_timer() {
        let mut c = IntervalCutCoordinator::new_at(10.0, 300.0, 2_000.0, 0.0, base_dt());
        c.register_channel("mic");

        // The old minimum made this a valid silence timer.  Raising the
        // minimum to 30s must not carry that timer into the new eligible
        // window, otherwise the next cut would be shorter than 30s.
        c.report_silence("mic", true, 10.0);
        c.set_params(30.0, 300.0, 2_000.0);
        c.report_silence("mic", true, 30.0);
        c.report_silence("mic", true, 31.99);
        assert!(c.check_cut(31.99).is_none());
        c.report_silence("mic", true, 32.01);

        let cut = c.check_cut(32.01).expect("cut after the new minimum");
        let duration_s = (cut.end_at - cut.start_at).num_milliseconds() as f64 / 1000.0;
        assert!(duration_s >= 30.0, "got {duration_s}s after min increase");
    }

    #[test]
    fn continuous_silence_after_max_reset_respects_min() {
        let mut c = IntervalCutCoordinator::new_at(30.0, 300.0, 2_000.0, 0.0, base_dt());
        c.register_channel("mic");

        c.report_silence("mic", false, 300.0);
        let first = c.check_cut(300.0).expect("forced max cut");
        assert_eq!(
            (first.end_at - first.start_at).num_seconds(),
            300,
            "forced max cut should end at the max boundary"
        );

        // The next interval starts at the max boundary.  Continuous silence
        // must wait for the new 30s minimum before the 2s gap can cut it.
        c.report_silence("mic", true, 300.01);
        c.report_silence("mic", true, 330.0);
        assert!(c.check_cut(330.0).is_none());
        c.report_silence("mic", true, 332.01);
        let second = c.check_cut(332.01).expect("post-reset silence cut");
        let duration_s = (second.end_at - second.start_at).num_milliseconds() as f64 / 1000.0;
        assert!(duration_s >= 30.0);
        assert!(duration_s <= 300.0);
    }

    #[test]
    fn silence_cut_between_min_and_max_at_gap_center() {
        let mut c = coord_one_channel();
        // Cross min with speech so silence timer starts fresh after min.
        c.report_silence("mic", false, 310.0);
        // Silence starts at 320, must persist >= 2000ms.
        c.report_silence("mic", true, 320.0); // start silence
        assert!(c.check_cut(320.0).is_none());
        c.report_silence("mic", true, 322.0); // 2000ms elapsed -> cut

        let cut = c.check_cut(322.0).expect("silence cut");
        // Cut at center: silence_start + silence_cut_ms/2000 = 320 + 1.0 = 321.0
        let expected_elapsed: f64 = 321.0; // from interval start (0.0)
        assert_eq!(
            cut.sample_offset,
            (expected_elapsed * 16000.0).round() as usize
        );
        assert_eq!(cut.sample_offset, 321 * 16000);
        assert_eq!(cut.start_at, base_dt());
        assert_eq!(cut.end_at, base_dt() + Duration::seconds(321));
    }

    #[test]
    fn speech_in_one_channel_prevents_cut() {
        let mut c = coord();
        c.register_channel("a");
        c.register_channel("b");

        // Past min. Channel a silent, channel b speaking.
        c.report_silence("a", true, 320.0);
        c.report_silence("b", false, 320.0); // not all silent -> resets
        c.report_silence("a", true, 325.0);
        c.report_silence("b", false, 325.0);
        assert!(c.check_cut(325.0).is_none());

        // Now both silent but not long enough yet.
        c.report_silence("a", true, 400.0);
        c.report_silence("b", true, 400.0); // silence_start = 400
        c.report_silence("a", true, 400.5);
        c.report_silence("b", true, 400.5); // 500ms < 2000ms
        assert!(c.check_cut(400.5).is_none());

        // Speech again resets the timer.
        c.report_silence("b", false, 401.0);
        assert!(c.silence_start_mono.is_none());

        // Both silent continuously for >= 2000ms -> cut.
        c.report_silence("a", true, 410.0);
        c.report_silence("b", true, 410.0); // start
        c.report_silence("a", true, 412.0);
        c.report_silence("b", true, 412.0); // 2000ms -> cut
        let cut = c.check_cut(412.0).expect("cut after both silent");
        // center = 410 + 1.0 = 411.0
        assert_eq!(cut.sample_offset, (411.0_f64 * 16000.0).round() as usize);
    }

    #[test]
    fn flush_current_skips_short_remainder() {
        let mut c = coord_one_channel();
        c.report_silence("mic", false, 0.2);
        // elapsed 0.4 < 0.5 -> None
        assert!(c.flush_current(0.4).is_none());
    }

    #[test]
    fn flush_current_cuts_remainder() {
        let mut c = coord_one_channel();
        c.report_silence("mic", false, 5.0);
        let cut = c.flush_current(12.5).expect("flush cut");
        assert_eq!(cut.sample_offset, (12.5_f64 * 16000.0).round() as usize);
        assert_eq!(cut.start_at, base_dt());
        // 12.5s -> 12s 500ms
        assert_eq!(cut.end_at, base_dt() + Duration::milliseconds(12_500));
    }

    #[test]
    fn consecutive_intervals_are_contiguous() {
        let mut c = coord_one_channel();

        // First cut at max.
        c.report_silence("mic", false, MAX);
        let cut1 = c.check_cut(MAX).expect("first cut");
        let boundary = cut1.end_at;
        assert_eq!(cut1.start_at, base_dt());

        // The next interval started at the cut time. Drive a silence cut.
        // Use absolute mono times continuing from MAX.
        let t0 = MAX; // new interval start mono
                      // Past min relative to new start.
        c.report_silence("mic", false, t0 + 310.0);
        c.report_silence("mic", true, t0 + 320.0); // silence start
        c.report_silence("mic", true, t0 + 322.0); // 2000ms -> cut
        let cut2 = c.check_cut(t0 + 322.0).expect("second cut");

        // Start of interval 2 == end of interval 1.
        assert_eq!(cut2.start_at, boundary);
        // sample_offset measured from new interval start: center 321.0s.
        assert_eq!(cut2.sample_offset, (321.0_f64 * 16000.0).round() as usize);
        // end_at = boundary + 321s.
        assert_eq!(cut2.end_at, boundary + Duration::seconds(321));
    }

    /// Настенная и монотонная шкалы не должны расходиться: сумма длительностей
    /// серии интервалов равна пройденному монотонному времени (до мс).
    ///
    /// Раньше каждый рез по тишине «терял» `silence_cut_ms/2` (~1с при дефолте):
    /// длительности занижались, а соответствующее аудио навсегда оставалось в
    /// буфере канала.
    #[test]
    fn interval_timeline_does_not_drift_across_silence_cuts() {
        let mut c = IntervalCutCoordinator::new_at(30.0, 300.0, 2_000.0, 0.0, base_dt());
        c.register_channel("mic");

        let mut total_ms = 0_i64;
        let mut t = 0.0_f64;
        let mut last_cut_mono = 0.0_f64;
        for _ in 0..4 {
            // Речь до минимума, затем пауза 2с -> рез в её середине.
            t += 31.0;
            c.report_silence("mic", false, t);
            t += 1.0;
            c.report_silence("mic", true, t); // начало тишины
            let silence_start = t;
            t += 2.0;
            c.report_silence("mic", true, t); // порог тишины достигнут
            t += 0.05; // рез забирают следующим тиком DSP, а не мгновенно
            let cut = c.check_cut(t).expect("рез по тишине");
            total_ms += (cut.end_at - cut.start_at).num_milliseconds();
            last_cut_mono = silence_start + 1.0; // центр паузы
        }

        // Сумма длительностей == монотонное время последнего реза (допуск —
        // округление наносекунд, а не потерянные секунды: баг давал −1с на рез).
        let expected_ms = (last_cut_mono * 1000.0).round() as i64;
        assert!(
            (total_ms - expected_ms).abs() <= 5,
            "сумма длительностей {total_ms} мс против монотонных {expected_ms} мс"
        );

        // И «сейчас» на обеих шкалах — одно и то же: настенное начало текущего
        // интервала плюс его elapsed равны монотонному времени.
        let info = c.current_interval_info(t);
        let wall_offset_s = (info.start_at - base_dt()).num_milliseconds() as f64 / 1000.0;
        // Допуск 0.1с — это шаг округления `elapsed_s`, а не дрейф.
        assert!(
            (wall_offset_s + info.elapsed_s - t).abs() <= 0.1,
            "дрейф шкал: wall {wall_offset_s} + elapsed {} != mono {t}",
            info.elapsed_s
        );
    }

    /// Аудио между резами не должно «застревать»: смещение реза считается от
    /// начала интервала, поэтому остаток буфера обязан равняться ровно тому,
    /// что накопилось в текущем (ещё не нарезанном) интервале.
    #[test]
    fn cut_offsets_account_for_every_sample_of_the_timeline() {
        let mut c = IntervalCutCoordinator::new_at(30.0, 300.0, 2_000.0, 0.0, base_dt());
        c.register_channel("mic");

        // Модель буфера канала: сэмплы «поступают» ровно в реальном времени.
        let samples_at = |mono: f64| (mono * TARGET_SAMPLE_RATE as f64).round() as i64;
        let mut consumed: i64 = 0;
        let mut t = 0.0_f64;
        for _ in 0..3 {
            t += 31.0;
            c.report_silence("mic", false, t);
            t += 1.0;
            c.report_silence("mic", true, t);
            t += 2.0;
            c.report_silence("mic", true, t);
            t += 0.05;
            let cut = c.check_cut(t).expect("рез");
            consumed += cut.sample_offset as i64;
        }

        let pushed = samples_at(t);
        let leftover = pushed - consumed;
        let current_interval_s = c.current_interval_info(t).elapsed_s;
        assert!(
            (leftover - samples_at(current_interval_s)).abs() <= TARGET_SAMPLE_RATE as i64 / 10,
            "в буфере застряло {leftover} сэмплов вместо {} (текущий интервал {current_interval_s}с)",
            samples_at(current_interval_s)
        );
    }

    #[test]
    fn set_params_lowers_max_and_forces_earlier_cut() {
        let mut c = coord_one_channel();
        // При исходном MAX=600 в момент 400с реза ещё нет (речь идёт постоянно).
        c.report_silence("mic", false, 400.0);
        assert!(c.check_cut(400.0).is_none());

        // Горячо снижаем max до 350с — следующий же отчёт должен форсировать рез,
        // т.к. elapsed (410) уже превысил новый max.
        c.set_params(MIN, 350.0, SILENCE_MS);
        c.report_silence("mic", false, 410.0);
        let cut = c.check_cut(410.0).expect("force cut after lowering max");
        assert_eq!(cut.sample_offset, (410.0_f64 * 16000.0).round() as usize);
    }

    #[test]
    fn set_params_changes_silence_cut_threshold() {
        let mut c = coord_one_channel();
        // Сразу же ужесточаем порог тишины до 4000мс (был 2000).
        c.set_params(MIN, MAX, 4000.0);
        // Прошли min, началась тишина в 320с.
        c.report_silence("mic", false, 310.0);
        c.report_silence("mic", true, 320.0); // старт тишины
                                              // 2000мс тишины при старом пороге хватило бы на рез, при новом — нет.
        c.report_silence("mic", true, 322.0);
        assert!(
            c.check_cut(322.0).is_none(),
            "2s silence must NOT cut at 4s threshold"
        );
        // 4000мс — теперь режем, центр = 320 + 4000/2000 = 322.0.
        c.report_silence("mic", true, 324.0);
        let cut = c.check_cut(324.0).expect("cut after 4s silence");
        assert_eq!(cut.sample_offset, (322.0_f64 * 16000.0).round() as usize);
    }

    #[test]
    fn current_interval_info_reports_state() {
        let mut c = coord_one_channel();
        c.report_silence("mic", true, 12.34);
        let info = c.current_interval_info(12.34);
        assert_eq!(info.start_at, base_dt());
        assert!((info.elapsed_s - 12.3).abs() < 1e-9);
        assert!(info.all_silent);
    }
}
