import SwiftUI
import VideoCoachCore

/// Comma-separated tag editor with autocomplete from the project's existing
/// tag pool. The bound tag array is kept in sync via `Tag.normalize(input:)`
/// only on commit (Enter or focus loss) — typing freely doesn't fight the
/// user with mid-edit normalization.
struct TagField: View {
    @Binding var tags: [String]
    /// Pool of existing tags to suggest from — typically derived from
    /// `Set(workspace.project.clips.flatMap(\.tags))`.
    let suggestions: Set<String>
    let onCommit: () -> Void

    @State private var text: String = ""
    @State private var didInitialize = false
    @State private var highlightedIndex: Int? = nil
    @State private var popoverManuallyDismissed = false
    @FocusState private var isFocused: Bool

    private var currentFragment: String {
        // The user's "active" fragment is the text after the last comma.
        // Suggestions match against this — typing "shot, set" surfaces only
        // tags starting with "set", not everything containing a previously
        // committed token.
        let last = text.split(separator: ",", omittingEmptySubsequences: false).last ?? ""
        return last.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var matchingSuggestions: [String] {
        let frag = currentFragment
        // Don't pop the popover when the field is empty — that would dump the
        // whole tag pool over an unrelated UI region the moment the field gets focus.
        guard !frag.isEmpty else { return [] }
        let alreadyChosen = Set(Tag.normalize(input: text))
        return suggestions
            .filter { $0.hasPrefix(frag) && $0 != frag && !alreadyChosen.contains($0) }
            .sorted()
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        TextField("tag1, tag2", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onAppear {
                if !didInitialize {
                    text = tags.joined(separator: ", ")
                    didInitialize = true
                }
            }
            .onChange(of: tags) { _, newTags in
                // Sync down only when not actively focused; otherwise we'd stomp
                // the user's mid-edit text every time the model echoes back.
                if !isFocused { text = newTags.joined(separator: ", ") }
            }
            .onSubmit { commit() }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commit()
                    highlightedIndex = nil
                    popoverManuallyDismissed = false
                }
            }
            .onChange(of: text) { _, _ in
                // Typing invalidates any prior highlight + un-dismisses an
                // escape-dismissed popover so the user gets fresh suggestions.
                highlightedIndex = nil
                popoverManuallyDismissed = false
            }
            // Catches the case where the parent EditorView is being torn down
            // (e.g. user clicked a different clip) while focus loss hasn't fired
            // — without this the in-flight text is dropped.
            .onDisappear { commit() }
            // ↓ advances the highlight (nil → 0 → 1 → ... clamped at last suggestion).
            .onKeyPress(.downArrow) {
                guard popoverIsVisible else { return .ignored }
                let next = (highlightedIndex ?? -1) + 1
                highlightedIndex = min(next, matchingSuggestions.count - 1)
                return .handled
            }
            // ↑ retreats (... → 1 → 0 → nil), then falls through so the user
            // can keep going past the top of the list to deselect.
            .onKeyPress(.upArrow) {
                guard popoverIsVisible, let cur = highlightedIndex else { return .ignored }
                highlightedIndex = cur == 0 ? nil : cur - 1
                return .handled
            }
            // Tab takes the highlighted suggestion if one is highlighted,
            // otherwise the top one. .ignored lets Tab do its normal
            // focus-advance thing when there's nothing to take.
            .onKeyPress(.tab) {
                if let suggestion = suggestionToTake {
                    applySuggestion(suggestion)
                    return .handled
                }
                return .ignored
            }
            // Enter accepts the highlighted suggestion when one is highlighted;
            // otherwise .ignored lets .onSubmit fire commit() on the raw text.
            .onKeyPress(.return) {
                guard let idx = highlightedIndex,
                      idx < matchingSuggestions.count else { return .ignored }
                applySuggestion(matchingSuggestions[idx])
                return .handled
            }
            // Esc dismisses the popover without losing focus or committing.
            .onKeyPress(.escape) {
                guard popoverIsVisible else { return .ignored }
                popoverManuallyDismissed = true
                highlightedIndex = nil
                return .handled
            }
            .popover(
                isPresented: Binding(
                    get: { popoverIsVisible },
                    set: { _ in }
                ),
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .bottom
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matchingSuggestions.enumerated()), id: \.element) { idx, suggestion in
                        Button {
                            applySuggestion(suggestion)
                        } label: {
                            HStack {
                                Text(suggestion)
                                Spacer()
                                if idx == effectiveTakeIndex {
                                    Text("⇥ tab").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(idx == highlightedIndex ? Color.accentColor.opacity(0.18) : Color.clear)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(minWidth: 160)
                .padding(.vertical, 4)
            }
    }

    private var popoverIsVisible: Bool {
        isFocused && !matchingSuggestions.isEmpty && !popoverManuallyDismissed
    }

    /// The suggestion Tab will take. Highlighted one if there is one,
    /// otherwise the top of the list.
    private var suggestionToTake: String? {
        if let idx = highlightedIndex, idx < matchingSuggestions.count {
            return matchingSuggestions[idx]
        }
        return matchingSuggestions.first
    }

    /// Where to render the "⇥ tab" hint — on the highlighted row if there is one,
    /// otherwise the top row.
    private var effectiveTakeIndex: Int {
        highlightedIndex ?? 0
    }

    private func commit() {
        let normalized = Tag.normalize(input: text)
        if normalized != tags {
            tags = normalized
            onCommit()
        }
        text = normalized.joined(separator: ", ")
    }

    private func applySuggestion(_ suggestion: String) {
        // Replace the active fragment with the chosen suggestion, then add a
        // trailing ", " so the user can keep typing the next tag.
        var parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if parts.isEmpty { parts = [""] }
        parts[parts.count - 1] = " " + suggestion
        text = parts.joined(separator: ",") + ", "
        commit()
        // Re-open the field for the next entry without losing focus.
        isFocused = true
    }
}
