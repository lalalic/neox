//! Validate optional preview URL parameters. File Server never converts or trims media.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Clip {
    pub start: f64,
    pub duration: f64,
}

/// A clip is a time slice of its source, not a byte range. Keep it explicit.
pub fn parse_clip(query: &str) -> Result<Option<Clip>, ()> {
    if query.is_empty() {
        return Ok(None);
    }
    let mut start = None;
    let mut duration = None;
    let mut version_seen = false;
    for field in query.split('&') {
        let (key, value) = field.split_once('=').ok_or(())?;
        if key == "pv" {
            if version_seen || value.len() != 16 || !value.bytes().all(|b| b.is_ascii_hexdigit()) {
                return Err(());
            }
            version_seen = true;
            continue;
        }
        let value = value.parse::<f64>().map_err(|_| ())?;
        if !value.is_finite() {
            return Err(());
        }
        match key {
            "startSeconds" if start.is_none() && (0.0..=86400.0).contains(&value) => {
                start = Some(value)
            }
            "durationSeconds"
                if duration.is_none() && (0.0..=600.0).contains(&value) && value > 0.0 =>
            {
                duration = Some(value)
            }
            _ => return Err(()),
        }
    }
    match (start, duration) {
        (None, None) if version_seen => Ok(None),
        (Some(start), Some(duration)) if start + duration <= 86400.0 => {
            Ok(Some(Clip { start, duration }))
        }
        _ => Err(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validates_clip_ranges_and_rejects_unknown_arguments() {
        assert_eq!(parse_clip(""), Ok(None));
        assert_eq!(parse_clip("pv=1234567890abcdef"), Ok(None));
        assert_eq!(
            parse_clip("pv=1234567890abcdef&startSeconds=1&durationSeconds=2"),
            Ok(Some(Clip {
                start: 1.0,
                duration: 2.0
            }))
        );
        assert_eq!(
            parse_clip("startSeconds=12.5&durationSeconds=4"),
            Ok(Some(Clip {
                start: 12.5,
                duration: 4.0
            }))
        );
        for bad in [
            "startSeconds=4",
            "durationSeconds=5",
            "startSeconds=-1&durationSeconds=5",
            "startSeconds=0&durationSeconds=0",
            "startSeconds=0&durationSeconds=NaN",
            "startSeconds=0&durationSeconds=600&x=1",
            "startSeconds=0&startSeconds=1&durationSeconds=5",
            "pv=nothex",
            "pv=1234567890abcdef&pv=1234567890abcdef",
        ] {
            assert!(parse_clip(bad).is_err(), "{bad}");
        }
    }
}
