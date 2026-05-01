use crate::project::{Codec, Quality, Resolution};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PixelSize {
    pub width: u32,
    pub height: u32,
}

/// Target encoder bitrate (bits-per-second) for the given resolution,
/// quality and codec.
///
/// HEVC bitrates are ~60% of H.264 for similar perceptual quality
/// (PSNR/VMAF), a common rule-of-thumb for sports footage.
pub fn bitrate(resolution: Resolution, quality: Quality, codec: Codec) -> u32 {
    let base_1080 = match (codec, quality) {
        (Codec::H264, Quality::Low) => 6_000_000,
        (Codec::H264, Quality::Medium) => 12_000_000,
        (Codec::H264, Quality::High) => 24_000_000,
        // HEVC ~60% of H.264 at the same perceptual quality level.
        (Codec::Hevc, Quality::Low) => 3_600_000,
        (Codec::Hevc, Quality::Medium) => 7_200_000,
        (Codec::Hevc, Quality::High) => 14_400_000,
    };
    match resolution {
        Resolution::Source | Resolution::R1080 => base_1080,
        Resolution::R720 => base_1080 / 2,
    }
}

pub fn pixel_size(resolution: Resolution) -> PixelSize {
    match resolution {
        // `Source` returns 1920x1080 as a placeholder — the export pipeline
        // overrides with the source asset's actual dimensions at render time.
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
    use crate::project::{Codec, Quality, Resolution};

    #[test]
    fn bitrate_for_resolution_and_quality() {
        // H.264 — base table.
        assert_eq!(
            bitrate(Resolution::R1080, Quality::Low, Codec::H264),
            6_000_000
        );
        assert_eq!(
            bitrate(Resolution::R1080, Quality::Medium, Codec::H264),
            12_000_000
        );
        assert_eq!(
            bitrate(Resolution::R1080, Quality::High, Codec::H264),
            24_000_000
        );
        assert_eq!(
            bitrate(Resolution::R720, Quality::Medium, Codec::H264),
            6_000_000
        );
        // Source resolution shares the 1080p table.
        assert_eq!(
            bitrate(Resolution::Source, Quality::High, Codec::H264),
            24_000_000
        );
        assert_eq!(
            bitrate(Resolution::R720, Quality::Low, Codec::H264),
            3_000_000
        );
        assert_eq!(
            bitrate(Resolution::R720, Quality::High, Codec::H264),
            12_000_000
        );

        // HEVC — ~60% of H.264 base.
        assert_eq!(
            bitrate(Resolution::R1080, Quality::Low, Codec::Hevc),
            3_600_000
        );
        assert_eq!(
            bitrate(Resolution::R1080, Quality::Medium, Codec::Hevc),
            7_200_000
        );
        assert_eq!(
            bitrate(Resolution::R1080, Quality::High, Codec::Hevc),
            14_400_000
        );
        // R720 HEVC = base_1080 / 2. High at R720 lands at exactly the
        // Medium-at-1080 value (7.2 Mbps) — useful sanity check that the
        // halving and the perceptual-quality offset don't collide.
        assert_eq!(
            bitrate(Resolution::R720, Quality::High, Codec::Hevc),
            7_200_000
        );
        assert_eq!(
            bitrate(Resolution::R720, Quality::Low, Codec::Hevc),
            1_800_000
        );
        assert_eq!(
            bitrate(Resolution::R720, Quality::Medium, Codec::Hevc),
            3_600_000
        );
        // Source resolution shares the 1080p HEVC table.
        assert_eq!(
            bitrate(Resolution::Source, Quality::Medium, Codec::Hevc),
            7_200_000
        );
    }

    #[test]
    fn pixel_size_source_passes_through() {
        assert_eq!(
            pixel_size(Resolution::Source),
            PixelSize {
                width: 1920,
                height: 1080
            }
        );
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
