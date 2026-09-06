//! Text cleaning, garbage filtering and whisper multi-candidate language
//! scoring. OWNER: module agent. Replace stubs; keep signatures.
//!
//! Port these behaviors 1:1 from the legacy Python (`transcriber.py`):
//! - MIN_TEXT_CHARS = 2
//! - GARBAGE_PATTERNS:
//!   `^\[(?:BLANK_AUDIO|Ambient|Motor|Noise|Music|Applause|M|S|Speech|Silence)\]$` (case-insensitive),
//!   `^\[[^\]]{1,24}\]$`
//! - clean: collapse whitespace, then trim "-—– " (dash/em-dash/en-dash/space)
//! - is_garbage: empty OR len<2 OR matches a garbage pattern OR <2 alphanumerics
//! - cyrillic count: chars in U+0430..U+044F plus 'ё'/'Ё'; latin: a-z (case-insensitive)
//! - score_text_for_lang: garbage => -10000; else
//!   score = alnum*2 + len; ru: +cyr*4 - lat*4; en: +lat*4 - cyr*4; else +max(cyr,lat)*2;
//!   +10 if >=2 words
//! - pick_best_candidate: per candidate score; +5 if lang in {ru,en}; +30 if is_auto;
//!   pick max; clean the winner; return None if winner is garbage.

use once_cell::sync::Lazy;
use regex::Regex;

pub const MIN_TEXT_CHARS: usize = 2;

#[derive(Clone, Debug, Default)]
pub struct Candidate {
    pub text: String,
    pub language: Option<String>,
    pub is_auto: bool,
}

/// Garbage patterns, compiled once. Mirrors the legacy `GARBAGE_PATTERNS`:
///   ^\[(?:BLANK_AUDIO|Ambient|Motor|Noise|Music|Applause|M|S|Speech|Silence)\]$  (case-insensitive)
///   ^\[[^\]]{1,24}\]$
static GARBAGE_PATTERNS: Lazy<[Regex; 2]> = Lazy::new(|| {
    [
        Regex::new(
            r"(?i)^\[(?:BLANK_AUDIO|Ambient|Motor|Noise|Music|Applause|M|S|Speech|Silence)\]$",
        )
        .expect("static garbage pattern 0 must compile"),
        Regex::new(r"^\[[^\]]{1,24}\]$").expect("static garbage pattern 1 must compile"),
    ]
});

pub fn count_words(text: &str) -> u32 {
    text.split_whitespace().filter(|w| !w.is_empty()).count() as u32
}

/// Collapse runs of whitespace to a single space, trim, then strip leading and
/// trailing dash/em-dash/en-dash/space characters ("-—– ").
pub fn clean_transcribed_text(text: &str) -> String {
    // Collapse whitespace (any run of unicode whitespace -> single space) and trim.
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    // Strip "-—– " from both ends.
    collapsed
        .trim_matches(|c: char| c == '-' || c == '\u{2014}' || c == '\u{2013}' || c == ' ')
        .to_string()
}

/// Counts characters in U+0430..=U+044F plus 'ё'/'Ё' (case-insensitive lower-cased compare).
pub fn count_cyrillic(text: &str) -> usize {
    text.chars()
        .filter(|ch| {
            ch.to_lowercase()
                .any(|lc| ('\u{0430}'..='\u{044f}').contains(&lc) || lc == '\u{0451}')
        })
        .count()
}

/// Counts ASCII latin letters (case-insensitive a-z).
pub fn count_latin(text: &str) -> usize {
    text.chars()
        .filter(|ch| ch.to_lowercase().any(|lc: char| lc.is_ascii_lowercase()))
        .count()
}

fn count_alnum(text: &str) -> usize {
    text.chars().filter(|ch| ch.is_alphanumeric()).count()
}

/// True if the (cleaned) text is empty, shorter than MIN_TEXT_CHARS, matches a
/// garbage pattern, or has fewer than 2 alphanumeric characters.
pub fn is_garbage_text(text: &str) -> bool {
    let text = clean_transcribed_text(text);
    if text.is_empty() || text.chars().count() < MIN_TEXT_CHARS {
        return true;
    }
    if GARBAGE_PATTERNS.iter().any(|p| {
        // full-match semantics: the anchored patterns already enforce ^...$
        p.is_match(&text)
    }) {
        return true;
    }
    count_alnum(&text) < 2
}

pub fn score_text_for_lang(text: &str, lang: &str) -> i64 {
    let text = clean_transcribed_text(text);
    if is_garbage_text(&text) {
        return -10000;
    }
    let cyr = count_cyrillic(&text) as i64;
    let lat = count_latin(&text) as i64;
    let alnum = count_alnum(&text) as i64;
    // len() in the Python original is character count (Python str len).
    let len = text.chars().count() as i64;
    let mut score = alnum * 2 + len;
    if lang == "ru" {
        score += cyr * 4 - lat * 4;
    } else if lang == "en" {
        score += lat * 4 - cyr * 4;
    } else {
        score += cyr.max(lat) * 2;
    }
    if count_words(&text) >= 2 {
        score += 10;
    }
    score
}

pub fn pick_best_candidate(candidates: &[Candidate]) -> Option<Candidate> {
    let mut best: Option<&Candidate> = None;
    let mut best_score: i64 = -10_000_000;
    for cand in candidates {
        let lang = match cand.language.as_deref() {
            Some(l) if !l.is_empty() => l,
            _ => "auto",
        };
        let mut score = score_text_for_lang(&cand.text, lang);
        if lang == "ru" || lang == "en" {
            score += 5;
        }
        if cand.is_auto {
            score += 30;
        }
        if score > best_score {
            best_score = score;
            best = Some(cand);
        }
    }
    let best = best?;
    let cleaned = clean_transcribed_text(&best.text);
    if is_garbage_text(&cleaned) {
        return None;
    }
    Some(Candidate {
        text: cleaned,
        language: best.language.clone(),
        is_auto: best.is_auto,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cand(text: &str, language: Option<&str>, is_auto: bool) -> Candidate {
        Candidate {
            text: text.to_string(),
            language: language.map(|s| s.to_string()),
            is_auto,
        }
    }

    #[test]
    fn clean_collapses_whitespace_and_trims() {
        assert_eq!(clean_transcribed_text("  hello   world  "), "hello world");
        assert_eq!(clean_transcribed_text("a\t\nb\r\nc"), "a b c");
        assert_eq!(clean_transcribed_text(""), "");
        assert_eq!(clean_transcribed_text("   "), "");
    }

    #[test]
    fn clean_strips_dashes() {
        assert_eq!(clean_transcribed_text("- hello -"), "hello");
        assert_eq!(clean_transcribed_text("—  привет  —"), "привет");
        assert_eq!(clean_transcribed_text("–word–"), "word");
        assert_eq!(clean_transcribed_text("-—– text –—-"), "text");
        // internal dash preserved
        assert_eq!(clean_transcribed_text("co-op"), "co-op");
    }

    #[test]
    fn garbage_blank_audio_tag() {
        assert!(is_garbage_text("[BLANK_AUDIO]"));
        assert!(is_garbage_text("[blank_audio]"));
        assert!(is_garbage_text("[Music]"));
        assert!(is_garbage_text("[Applause]"));
        assert!(is_garbage_text("[Silence]"));
        assert!(is_garbage_text("[M]"));
        assert!(is_garbage_text("[S]"));
    }

    #[test]
    fn garbage_short_bracket_tag() {
        // Generic bracket tag of 1..=24 chars inside
        assert!(is_garbage_text("[something]"));
        assert!(is_garbage_text("[шум за окном тут]"));
        // 24 chars inside -> garbage
        assert!(is_garbage_text("[123456789012345678901234]"));
        // 25 chars inside -> not matched by bracket pattern, but it has >=2 alnum
        // and is long, so it is NOT garbage.
        assert!(!is_garbage_text("[1234567890123456789012345]"));
    }

    #[test]
    fn garbage_empty_short_and_low_alnum() {
        assert!(is_garbage_text(""));
        assert!(is_garbage_text("   "));
        assert!(is_garbage_text("a")); // len < MIN_TEXT_CHARS
        assert!(is_garbage_text("..")); // 2 chars but <2 alnum
        assert!(is_garbage_text("-—")); // strips to empty
        assert!(is_garbage_text(". ,")); // <2 alnum
    }

    #[test]
    fn not_garbage_normal_text() {
        assert!(!is_garbage_text("Привет мир"));
        assert!(!is_garbage_text("Hello there"));
        assert!(!is_garbage_text("ok")); // 2 alnum, len 2
    }

    #[test]
    fn cyrillic_and_latin_counts() {
        assert_eq!(count_cyrillic("Привет"), 6);
        assert_eq!(count_cyrillic("ёЁ"), 2);
        assert_eq!(count_cyrillic("Hello"), 0);
        assert_eq!(count_latin("Hello"), 5);
        assert_eq!(count_latin("Привет"), 0);
        assert_eq!(count_latin("abcABC123"), 6);
    }

    #[test]
    fn scoring_cyrillic_vs_latin() {
        let ru_text = "это русский текст";
        let en_text = "this english text";
        // Russian text should score higher under "ru" than under "en".
        assert!(score_text_for_lang(ru_text, "ru") > score_text_for_lang(ru_text, "en"));
        // English text should score higher under "en" than under "ru".
        assert!(score_text_for_lang(en_text, "en") > score_text_for_lang(en_text, "ru"));
        // Garbage scores the sentinel.
        assert_eq!(score_text_for_lang("[BLANK_AUDIO]", "ru"), -10000);
        assert_eq!(score_text_for_lang("", "auto"), -10000);
    }

    #[test]
    fn scoring_exact_value_matches_python() {
        // "ab cd": clean -> "ab cd", alnum=4, len=5, lat=4, cyr=0
        // base = 4*2 + 5 = 13; ru: +0*4 - 4*4 = -16 => 13-16 = -3; words>=2 -> +10 => 7
        assert_eq!(score_text_for_lang("ab cd", "ru"), 7);
        // en: +4*4 - 0 = +16 => 13+16=29; +10 => 39
        assert_eq!(score_text_for_lang("ab cd", "en"), 39);
        // auto: +max(0,4)*2 = +8 => 13+8=21; +10 => 31
        assert_eq!(score_text_for_lang("ab cd", "auto"), 31);
        // single word: no +10. "abcd": alnum=4, len=4, base=12; auto +max=+8 => 20
        assert_eq!(score_text_for_lang("abcd", "auto"), 20);
    }

    #[test]
    fn pick_best_prefers_auto_bonus() {
        // Same text; auto candidate gets +30 and should win.
        let cands = vec![
            cand("hello world", Some("en"), false),
            cand("hello world", Some("en"), true),
        ];
        let best = pick_best_candidate(&cands).expect("should pick something");
        assert!(best.is_auto);
        assert_eq!(best.text, "hello world");
    }

    #[test]
    fn pick_best_ru_vs_en() {
        let cands = vec![
            cand("это русский текст здесь", Some("ru"), false),
            cand("xx", Some("en"), false),
        ];
        let best = pick_best_candidate(&cands).expect("should pick something");
        assert_eq!(best.language.as_deref(), Some("ru"));
    }

    #[test]
    fn pick_best_cleans_winner() {
        let cands = vec![cand("-—  Hello world  —-", Some("en"), false)];
        let best = pick_best_candidate(&cands).expect("should pick");
        assert_eq!(best.text, "Hello world");
    }

    #[test]
    fn pick_best_returns_none_when_all_garbage() {
        let cands = vec![
            cand("[BLANK_AUDIO]", Some("en"), true),
            cand("", None, false),
            cand("[noise]", None, false),
        ];
        assert!(pick_best_candidate(&cands).is_none());
    }

    #[test]
    fn pick_best_empty_input() {
        assert!(pick_best_candidate(&[]).is_none());
    }

    #[test]
    fn pick_best_missing_language_treated_as_auto() {
        let cands = vec![cand("hello world here", None, false)];
        let best = pick_best_candidate(&cands).expect("should pick");
        assert!(best.language.is_none());
        assert_eq!(best.text, "hello world here");
    }
}
