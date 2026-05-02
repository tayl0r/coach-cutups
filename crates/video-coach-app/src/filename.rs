// Phase 10 Task 0 lands the helper + tests; Task 2 wires the call site
// in `bus::handle` for `Command::ExportCompilations`. Until then the
// helper has no production caller, only tests — hence the dead_code
// allow at the module level.
#![allow(dead_code)]

//! Phase 10 Task 0 (fix #31). Windows-safe filename sanitization helper
//! used by the export bus handler when composing output filenames from
//! tag labels and project names.
//!
//! The bus turns `<output_folder>/<sanitize(label)> -
//! <sanitize(project_name)>.mp4` into a write target. macOS and Linux
//! tolerate most non-NUL bytes, but Windows rejects nine specific
//! characters (`/`, `\`, `:`, `*`, `?`, `"`, `<`, `>`, `|`) and treats a
//! short list of names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`,
//! `LPT1`–`LPT9`) as devices regardless of extension. Trailing dots and
//! whitespace also confuse Explorer + DOS-era APIs.
//!
//! Project files travel between platforms (we ship a Mac-built `.zip`
//! that someone double-clicks on Windows), so the bus sanitizes
//! aggressively — even on macOS-only builds — to keep batch outputs
//! portable.

/// Sanitize a string for use as a filename component (no extension).
///
/// Rules:
/// - Replace `/`, `\`, `:`, `*`, `?`, `"`, `<`, `>`, `|`, `\0` with `-`.
///   NUL was added per Plan #7 code-review #2: POSIX rejects NUL in
///   pathnames at the syscall layer, so a NUL smuggled through
///   `apply_template` (e.g. a tag containing a stray `\0` byte) would
///   otherwise survive sanitize and crash the file-write mid-batch.
/// - Trim leading/trailing whitespace and dots.
/// - If the result (case-insensitive) matches a Windows reserved name
///   (`CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9`), prefix
///   with `_`.
/// - If the result is empty after trimming, return `"untitled"`.
pub fn sanitize_filename(s: &str) -> String {
    // 1. Replace illegal chars.
    let replaced: String = s
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '\0' => '-',
            _ => c,
        })
        .collect();

    // 2. Trim whitespace + dots from both ends.
    let trimmed = replaced
        .trim_matches(|c: char| c.is_whitespace() || c == '.')
        .to_string();

    // 3. Empty → fallback.
    if trimmed.is_empty() {
        return "untitled".to_string();
    }

    // 4. Windows reserved-name guard. Compare case-insensitively against
    //    the bare name (no extension) — but our caller passes us the
    //    label/project component WITHOUT an extension, so the entire
    //    trimmed string is the candidate.
    if is_windows_reserved(&trimmed) {
        return format!("_{trimmed}");
    }

    trimmed
}

/// Strip `{` and `}` from substituent values BEFORE substitution so that
/// a tag/project/date containing literal braces cannot smuggle a
/// placeholder back into the partially-substituted template (Phase 11
/// Plan #7 fix #6). Without this, a project named `"My {tag} project"`
/// combined with template `"{tag} - {project}"` and tag `"X"` would
/// yield `"X - My {tag} project"` — a literal `{tag}` survives in the
/// filename. Stripping the braces from substituent values gives
/// `"X - My tag project"` instead.
fn strip_braces(s: &str) -> String {
    s.chars().filter(|c| *c != '{' && *c != '}').collect()
}

/// Substitute `{tag}`, `{project}`, `{date}` placeholders in `template`
/// then sanitize the result for use as a filename component.
///
/// Substitution is single-pass and non-recursive: a tag named literally
/// `"{tag}"` is first stripped of its braces (per Phase 11 Plan #7 fix
/// #6) so it does NOT re-substitute. Unsupported placeholders pass
/// through as literal text (e.g. `"{frame}"` survives unchanged in the
/// output — future-compatible).
///
/// Date format is hardcoded to `YYYY-MM-DD` in project LOCAL time
/// (NOT UTC) — this is a user-facing filename and a UTC date can
/// disagree with the calendar the user is looking at. The caller
/// supplies the formatted date string; this helper is timezone-agnostic.
///
/// The result is passed through `sanitize_filename` so any
/// substituted-in illegal Windows chars (`/`, `\`, `:` etc.) are
/// scrubbed. An empty post-substitution-and-sanitize result falls
/// back to `"untitled"` (inherited from `sanitize_filename`'s contract).
pub fn apply_template(template: &str, tag: &str, project: &str, date: &str) -> String {
    let tag_clean = strip_braces(tag);
    let project_clean = strip_braces(project);
    let date_clean = strip_braces(date);
    let substituted = template
        .replace("{tag}", &tag_clean)
        .replace("{project}", &project_clean)
        .replace("{date}", &date_clean);
    sanitize_filename(&substituted)
}

fn is_windows_reserved(s: &str) -> bool {
    let upper = s.to_ascii_uppercase();
    matches!(
        upper.as_str(),
        "CON"
            | "PRN"
            | "AUX"
            | "NUL"
            | "COM1"
            | "COM2"
            | "COM3"
            | "COM4"
            | "COM5"
            | "COM6"
            | "COM7"
            | "COM8"
            | "COM9"
            | "LPT1"
            | "LPT2"
            | "LPT3"
            | "LPT4"
            | "LPT5"
            | "LPT6"
            | "LPT7"
            | "LPT8"
            | "LPT9"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passes_through_simple_label() {
        assert_eq!(sanitize_filename("basketball"), "basketball");
    }

    #[test]
    fn replaces_illegal_chars_with_dash() {
        // Each Windows-illegal byte becomes a single `-`. Note `:` is
        // legal on macOS HFS+ Finder but NOT on the underlying APFS or
        // when copied to NTFS, so we replace it everywhere.
        assert_eq!(
            sanitize_filename("a/b\\c:d*e?f\"g<h>i|j"),
            "a-b-c-d-e-f-g-h-i-j"
        );
    }

    #[test]
    fn trims_leading_and_trailing_whitespace() {
        assert_eq!(sanitize_filename("  hello  "), "hello");
        assert_eq!(sanitize_filename("\thello\n"), "hello");
    }

    #[test]
    fn trims_leading_and_trailing_dots() {
        assert_eq!(sanitize_filename("...hello..."), "hello");
        assert_eq!(sanitize_filename(".hidden."), "hidden");
    }

    #[test]
    fn trims_mixed_whitespace_and_dots() {
        assert_eq!(sanitize_filename(" . hello . "), "hello");
    }

    #[test]
    fn empty_input_falls_back_to_untitled() {
        assert_eq!(sanitize_filename(""), "untitled");
    }

    #[test]
    fn whitespace_only_falls_back_to_untitled() {
        assert_eq!(sanitize_filename("   "), "untitled");
    }

    #[test]
    fn dots_only_falls_back_to_untitled() {
        assert_eq!(sanitize_filename("..."), "untitled");
    }

    #[test]
    fn illegal_chars_only_does_not_collapse_to_untitled() {
        // `/` becomes `-`; the result is "-----" which is non-empty
        // and not whitespace/dots. We leave it alone.
        assert_eq!(sanitize_filename("/////"), "-----");
    }

    #[test]
    fn windows_reserved_con_gets_underscore_prefix() {
        assert_eq!(sanitize_filename("CON"), "_CON");
    }

    #[test]
    fn windows_reserved_lowercase_con_gets_underscore_prefix() {
        // Reserved-name comparison is case-insensitive.
        assert_eq!(sanitize_filename("con"), "_con");
    }

    #[test]
    fn windows_reserved_mixed_case_aux_gets_underscore_prefix() {
        assert_eq!(sanitize_filename("Aux"), "_Aux");
    }

    #[test]
    fn windows_reserved_com1_through_com9_get_underscore_prefix() {
        for n in 1..=9 {
            let name = format!("COM{n}");
            assert_eq!(sanitize_filename(&name), format!("_{name}"));
        }
    }

    #[test]
    fn windows_reserved_lpt1_through_lpt9_get_underscore_prefix() {
        for n in 1..=9 {
            let name = format!("LPT{n}");
            assert_eq!(sanitize_filename(&name), format!("_{name}"));
        }
    }

    #[test]
    fn non_reserved_com_passes_through() {
        // COM10 / COM0 / COMx are NOT reserved — only COM1..=COM9.
        assert_eq!(sanitize_filename("COM10"), "COM10");
        assert_eq!(sanitize_filename("COM0"), "COM0");
        assert_eq!(sanitize_filename("COMA"), "COMA");
    }

    #[test]
    fn reserved_name_with_trailing_dot_still_caught() {
        // Trim runs BEFORE the reserved-name check, so "CON." → "CON" → "_CON".
        // This matches Windows' behavior: a trailing dot doesn't escape the
        // device-name treatment.
        assert_eq!(sanitize_filename("CON."), "_CON");
    }

    #[test]
    fn unicode_passes_through_unchanged() {
        // Japanese + emoji are valid on every modern filesystem we ship
        // to (APFS, NTFS, ext4, exFAT). Don't strip them.
        assert_eq!(sanitize_filename("バスケ"), "バスケ");
        assert_eq!(sanitize_filename("clip-🏀"), "clip-🏀");
    }

    #[test]
    fn nul_byte_is_replaced_with_dash() {
        // Plan #7 code-review #2. POSIX rejects NUL in pathnames at the
        // syscall layer, so a stray `\0` in a tag/project value (or a
        // template) MUST be scrubbed. Without this, a tag like
        // "clip\0name" passes through sanitize and `fs::File::create`
        // fails with EINVAL mid-batch.
        assert_eq!(sanitize_filename("clip\0name"), "clip-name");
        // Standalone NUL collapses to "-" (non-empty, so no fallback).
        assert_eq!(sanitize_filename("\0"), "-");
    }

    #[test]
    fn realistic_tag_with_illegal_path_separator() {
        // A user types "drills/3pt" as a tag name; the bus sanitizes
        // before joining the output_folder. The slash mustn't escape
        // into the path.
        assert_eq!(sanitize_filename("drills/3pt"), "drills-3pt");
    }

    // -----------------------------------------------------------------
    // Phase 11 Plan #7 — apply_template tests.
    // -----------------------------------------------------------------

    #[test]
    fn default_template_matches_phase_10_format() {
        // The default template reproduces Phase 10's hard-coded
        // `<tag> - <project>` format byte-for-byte. The supplied date
        // is irrelevant when the default template lacks `{date}`.
        assert_eq!(
            apply_template("{tag} - {project}", "drills", "MyProj", "2026-05-01"),
            "drills - MyProj"
        );
    }

    #[test]
    fn template_with_date_substitutes_supplied_date() {
        // `{date}` is substituted with the caller-supplied date string
        // verbatim (the helper is timezone-agnostic; the bus formats
        // the date and hands it in).
        assert_eq!(
            apply_template("{date}_{tag}_{project}", "a", "P", "2026-05-01"),
            "2026-05-01_a_P"
        );
    }

    #[test]
    fn template_with_no_placeholders_passes_through() {
        // A template with no placeholders sanitizes-through unchanged.
        assert_eq!(
            apply_template("static-name", "anything", "anything", "anything"),
            "static-name"
        );
    }

    #[test]
    fn template_with_unknown_placeholder_passes_through_literal() {
        // `{frame}` is not a recognized placeholder; it survives in the
        // output verbatim. `{` and `}` are NOT in `sanitize_filename`'s
        // illegal-char list, so they pass through.
        assert_eq!(apply_template("{frame}_{tag}", "a", "X", "d"), "{frame}_a");
    }

    #[test]
    fn template_substitutes_into_illegal_chars_safely() {
        // A tag containing `/` substitutes into the template; the
        // post-substitution sanitize replaces the `/` with `-`.
        assert_eq!(apply_template("{tag}", "a/b", "P", "d"), "a-b");
    }

    #[test]
    fn template_substitutes_project_with_colon() {
        // A project name containing `:` substitutes; sanitize replaces
        // it with `-`.
        assert_eq!(
            apply_template("{project}", "tag", "5:30 drill", "d"),
            "5-30 drill"
        );
    }

    #[test]
    fn empty_template_falls_back_to_untitled() {
        // An empty template sanitizes to `"untitled"` per the existing
        // contract. The bus's pre-Export validation catches this case
        // upstream; the helper still produces a safe filename.
        assert_eq!(apply_template("", "x", "y", "d"), "untitled");
    }

    #[test]
    fn template_with_only_placeholders_resolving_to_empty_falls_back() {
        // `{tag}` only, with empty tag, substitutes to `""` and
        // sanitizes to `"untitled"`.
        assert_eq!(apply_template("{tag}", "", "P", "d"), "untitled");
    }

    #[test]
    fn windows_reserved_template_result_gets_underscore() {
        // A tag of `"CON"` substituted into `"{tag}"` post-sanitizes to
        // `"_CON"` per the Windows reserved-name guard.
        assert_eq!(apply_template("{tag}", "CON", "P", "d"), "_CON");
    }

    #[test]
    fn template_substituent_with_braces_is_stripped() {
        // A project name containing literal `{tag}` gets its braces
        // stripped before substitution (Plan #7 fix #6) — otherwise the
        // surviving `{tag}` would re-substitute into a tag value mid-
        // template and produce confusing filenames.
        assert_eq!(
            apply_template("{tag} - {project}", "X", "My {tag} project", "d"),
            "X - My tag project"
        );
    }

    #[test]
    fn template_with_literal_tag_in_input_is_not_recursively_substituted() {
        // A tag literally named `"{tag}"` has its braces stripped first
        // (fix #6), so it substitutes as `"tag"` — NOT recursively
        // re-substituted as another `{tag}` round. Documents the non-
        // recursive contract.
        assert_eq!(
            apply_template("{tag}_{project}", "{tag}", "P", "d"),
            "tag_P"
        );
    }
}
