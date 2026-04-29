use crate::project::Project;
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq)]
pub struct TagSummary {
    pub tag: String,
    pub clip_count: usize,
    pub total_duration_seconds: f64,
}

pub fn aggregate(project: &Project) -> Vec<TagSummary> {
    let mut by_tag: BTreeMap<String, (usize, f64)> = BTreeMap::new();
    for clip in &project.clips {
        for tag in &clip.tags {
            let entry = by_tag.entry(tag.clone()).or_insert((0, 0.0));
            entry.0 += 1;
            entry.1 += clip.recording_duration;
        }
    }
    by_tag
        .into_iter()
        .map(|(tag, (count, dur))| TagSummary {
            tag,
            clip_count: count,
            total_duration_seconds: dur,
        })
        .collect() // BTreeMap iteration is already sorted by key
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::Clip;
    use chrono::Utc;
    use uuid::Uuid;

    fn make_project(clips: &[(&str, &[&str], f64)]) -> Project {
        let mut p = Project::new("Test");
        for (i, (name, tags, dur)) in clips.iter().enumerate() {
            p.clips.push(Clip {
                id: Uuid::new_v4(),
                name: (*name).to_string(),
                notes: String::new(),
                tags: tags.iter().map(|t| (*t).to_string()).collect(),
                source_index: 0,
                start_source_seconds: 0.0,
                recording_duration: *dur,
                recording_filename: "x.mov".to_string(),
                events: Vec::new(),
                sort_index: i as i64,
                created_at: Utc::now(),
            });
        }
        p
    }

    #[test]
    fn test_aggregates_by_tag_with_count_and_duration() {
        let project = make_project(&[
            ("c1", &["attacking-chance", "wing"], 4.0),
            ("c2", &["attacking-chance"], 6.0),
            ("c3", &["transitions"], 3.0),
        ]);
        let summaries = aggregate(&project);
        let tags: std::collections::HashSet<String> =
            summaries.iter().map(|s| s.tag.clone()).collect();
        let expected: std::collections::HashSet<String> =
            ["attacking-chance", "transitions", "wing"]
                .iter()
                .map(|s| (*s).to_string())
                .collect();
        assert_eq!(tags, expected);

        let attacking = summaries
            .iter()
            .find(|s| s.tag == "attacking-chance")
            .expect("attacking-chance entry must exist");
        assert_eq!(attacking.clip_count, 2);
        assert_eq!(attacking.total_duration_seconds, 10.0);
    }

    #[test]
    fn test_is_alphabetically_sorted() {
        let project = make_project(&[
            ("c1", &["zebra"], 1.0),
            ("c2", &["alpha"], 1.0),
            ("c3", &["mango"], 1.0),
        ]);
        let summaries = aggregate(&project);
        let tags: Vec<String> = summaries.iter().map(|s| s.tag.clone()).collect();
        assert_eq!(tags, vec!["alpha", "mango", "zebra"]);
    }
}
