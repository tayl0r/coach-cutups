use crate::project::{Quality, Resolution};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PixelSize {
    pub width: u32,
    pub height: u32,
}

pub fn bitrate(resolution: Resolution, quality: Quality) -> u32 {
    let base_1080 = match quality {
        Quality::Low => 6_000_000,
        Quality::Medium => 12_000_000,
        Quality::High => 24_000_000,
    };
    match resolution {
        Resolution::Source | Resolution::R1080 => base_1080,
        Resolution::R720 => base_1080 / 2,
    }
}

pub fn pixel_size(resolution: Resolution) -> PixelSize {
    match resolution {
        Resolution::Source | Resolution::R1080 => PixelSize {
            width: 1920,
            height: 1080,
        },
        Resolution::R720 => PixelSize {
            width: 1280,
            height: 720,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{Quality, Resolution};

    #[test]
    fn bitrate_for_resolution_and_quality() {
        assert_eq!(bitrate(Resolution::R1080, Quality::Low), 6_000_000);
        assert_eq!(bitrate(Resolution::R1080, Quality::Medium), 12_000_000);
        assert_eq!(bitrate(Resolution::R1080, Quality::High), 24_000_000);
        assert_eq!(bitrate(Resolution::R720, Quality::Medium), 6_000_000);
    }

    #[test]
    fn pixel_size_source_passes_through() {
        assert_eq!(
            pixel_size(Resolution::R1080),
            PixelSize {
                width: 1920,
                height: 1080
            }
        );
        assert_eq!(
            pixel_size(Resolution::R720),
            PixelSize {
                width: 1280,
                height: 720
            }
        );
    }
}
