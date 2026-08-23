//! One timestamp format, one direction.
//!
//! Claude writes `2026-08-23T10:09:58.290Z` and opencode writes epoch millis, so
//! something has to convert. A date crate for one fixed-shape string is a dependency
//! this crate does not need, and a wrong answer here is visible immediately (records
//! out of order), so the arithmetic is written out.

/// Epoch millis for an RFC 3339 timestamp in UTC, or `None` if it is not one.
///
/// Only the `Z` form is accepted, which is the only one either CLI writes. An offset
/// we silently read as UTC would put a record an hour out of place, and a `None` a
/// consumer can see beats a number it cannot check.
pub fn epoch_ms(text: &str) -> Option<i64> {
    let bytes = text.as_bytes();
    if bytes.len() < 20 || bytes[4] != b'-' || bytes[7] != b'-' || bytes[10] != b'T' {
        return None;
    }
    if *bytes.last()? != b'Z' {
        return None;
    }
    let year: i64 = text.get(0..4)?.parse().ok()?;
    let month: i64 = text.get(5..7)?.parse().ok()?;
    let day: i64 = text.get(8..10)?.parse().ok()?;
    let hour: i64 = text.get(11..13)?.parse().ok()?;
    let minute: i64 = text.get(14..16)?.parse().ok()?;
    let second: i64 = text.get(17..19)?.parse().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }

    // Fractional seconds, however many digits the writer chose to use.
    let millis = match text.as_bytes().get(19) {
        Some(b'.') => {
            let frac: String = text[20..text.len() - 1]
                .chars()
                .take_while(char::is_ascii_digit)
                .collect();
            if frac.is_empty() {
                return None;
            }
            let scaled = format!("{frac:0<3}");
            scaled.get(0..3)?.parse().ok()?
        }
        Some(b'Z') => 0,
        _ => return None,
    };

    let days = days_from_civil(year, month, day);
    Some(((days * 86_400 + hour * 3_600 + minute * 60 + second) * 1_000) + millis)
}

/// Days since 1970-01-01, by Howard Hinnant's civil-from-days inverse. Shifting the
/// year to start in March is what removes the leap-day special case.
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = year - i64::from(month <= 2);
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let yoe = year - era * 400;
    let doy = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_epoch_and_a_real_transcript_stamp_both_land_where_they_should() {
        assert_eq!(epoch_ms("1970-01-01T00:00:00.000Z"), Some(0));
        assert_eq!(epoch_ms("1970-01-01T00:00:00Z"), Some(0));
        // 2026-08-23T10:09:58.290Z, copied out of a real claude transcript.
        assert_eq!(
            epoch_ms("2026-08-23T10:09:58.290Z"),
            Some(1_787_479_798_290)
        );
        // A leap day, which is where a hand-rolled conversion usually goes wrong.
        assert_eq!(
            epoch_ms("2024-02-29T12:00:00.000Z"),
            Some(1_709_208_000_000)
        );
        assert_eq!(epoch_ms("2000-02-29T00:00:00.000Z"), Some(951_782_400_000));
    }

    #[test]
    fn fractional_digits_are_read_as_a_fraction_not_as_millis() {
        assert_eq!(
            epoch_ms("2026-08-23T10:09:58.2Z").unwrap()
                - epoch_ms("2026-08-23T10:09:58.000Z").unwrap(),
            200
        );
        assert_eq!(
            epoch_ms("2026-08-23T10:09:58.123456Z").unwrap()
                - epoch_ms("2026-08-23T10:09:58.000Z").unwrap(),
            123
        );
    }

    #[test]
    fn anything_that_is_not_a_utc_stamp_is_no_answer_rather_than_a_wrong_one() {
        assert_eq!(epoch_ms(""), None);
        assert_eq!(epoch_ms("not a date"), None);
        assert_eq!(epoch_ms("2026-08-23"), None);
        // An offset read as UTC would be an hour out; refuse it instead.
        assert_eq!(epoch_ms("2026-08-23T10:09:58.290+01:00"), None);
        assert_eq!(epoch_ms("2026-13-01T00:00:00.000Z"), None);
    }
}
