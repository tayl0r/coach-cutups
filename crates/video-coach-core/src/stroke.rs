use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rgba {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
}

impl Rgba {
    pub const RED: Rgba = Rgba {
        r: 1.0,
        g: 0.2,
        b: 0.2,
        a: 1.0,
    };
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StrokePoint {
    pub x: f64, // 0...1 of frame width
    pub y: f64, // 0...1 of frame height
    pub t: f64, // seconds since stroke start
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Stroke {
    pub id: Uuid,
    pub color: Rgba,
    pub line_width: f64, // normalized to frame height
    pub points: Vec<StrokePoint>,
    pub auto_clear_after_seconds: Option<f64>, // None = persist
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn red_constant_matches_swift() {
        assert_eq!(
            Rgba::RED,
            Rgba {
                r: 1.0,
                g: 0.2,
                b: 0.2,
                a: 1.0
            }
        );
    }

    #[test]
    fn stroke_roundtrips_through_json() {
        let s = Stroke {
            id: Uuid::nil(),
            color: Rgba::RED,
            line_width: 0.012,
            points: vec![StrokePoint {
                x: 0.5,
                y: 0.5,
                t: 0.0,
            }],
            auto_clear_after_seconds: Some(5.0),
        };
        let json = serde_json::to_string(&s).unwrap();
        let back: Stroke = serde_json::from_str(&json).unwrap();
        assert_eq!(s, back);
    }

    #[test]
    fn stroke_serializes_with_camelcase_keys() {
        let s = Stroke {
            id: Uuid::nil(),
            color: Rgba::RED,
            line_width: 0.012,
            points: vec![],
            auto_clear_after_seconds: None,
        };
        let json = serde_json::to_value(&s).unwrap();
        let obj = json.as_object().unwrap();
        assert!(
            obj.contains_key("lineWidth"),
            "expected camelCase `lineWidth`, got: {:?}",
            obj.keys().collect::<Vec<_>>()
        );
        assert!(obj.contains_key("autoClearAfterSeconds"));
    }
}
