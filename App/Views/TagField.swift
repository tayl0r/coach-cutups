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
                if !focused { commit() }
            }
            // Catches the case where the parent EditorView is being torn down
            // (e.g. user clicked a different clip) while focus loss hasn't fired
            // — without this the in-flight text is dropped.
            .onDisappear { commit() }
            // Tab accepts the top suggestion when the popover is visible. When
            // there's no suggestion to take, .ignored lets Tab do its normal
            // focus-advance thing.
            .onKeyPress(.tab) {
                if let top = matchingSuggestions.first {
                    applySuggestion(top)
                    return .handled
                }
                return .ignored
            }
            .popover(
                isPresented: Binding(
                    get: { isFocused && !matchingSuggestions.isEmpty },
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
                                if idx == 0 {
                                    Text("⇥ tab").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(minWidth: 160)
                .padding(.vertical, 4)
            }
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
