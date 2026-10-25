import ResonoteKit
import SwiftUI

/// Display name, bio, and the genres shown on the profile.
struct EditProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let original: Profile
    @State private var displayName: String
    @State private var bio: String
    @State private var genreIds: [String]
    @State private var genres: [GenreOption]?
    @State private var genresError: String?
    @State private var confirmDiscard = false

    private static let maxGenres = 40
    private static let maxBio = 600

    init(profile: Profile) {
        original = profile
        _displayName = State(initialValue: profile.displayName)
        _bio = State(initialValue: profile.bio)
        _genreIds = State(initialValue: profile.genreIds)
    }

    private var trimmedName: String { displayName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBio: String { bio.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDirty: Bool {
        trimmedName != original.displayName || trimmedBio != original.bio || genreIds != original.genreIds
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Display name", text: $displayName)
                        .textContentType(.name)
                        .submitLabel(.done)
                }
                .listRowBackground(RN.Palette.paper2)

                Section {
                    TextField("Bio", text: $bio, prompt: Text("What you listen for"), axis: .vertical)
                        .lineLimit(3...8)
                        .onChange(of: bio) { _, value in
                            if value.count > Self.maxBio { bio = String(value.prefix(Self.maxBio)) }
                        }
                } header: {
                    Text("Bio")
                } footer: {
                    Text("\(bio.count) of \(Self.maxBio)")
                        .monospacedDigit()
                }
                .listRowBackground(RN.Palette.paper2)

                Section {
                    genrePicker
                        .padding(.vertical, RN.Space.xs)
                } header: {
                    Text("Genres")
                } footer: {
                    Text("They describe what you listen to. They do not lock you into a genre profile.")
                }
                .listRowBackground(RN.Palette.paper2)
            }
            .journalFormStyle()
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if isDirty { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmedName.isEmpty || !isDirty)
                }
            }
            .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .task { await loadGenres() }
        }
        .interactiveDismissDisabled(isDirty)
        .holdsUnsavedInput(isDirty)
    }

    // MARK: Genres

    @ViewBuilder
    private var genrePicker: some View {
        if let genres {
            ProfileGenrePicker(genreIds: $genreIds, options: genres, limit: Self.maxGenres)
        } else if let genresError {
            VStack(alignment: .leading, spacing: RN.Space.s) {
                ReservedErrorRow(message: genresError)
                Button("Try again") { Task { await loadGenres() } }
                    .buttonStyle(.outline)
            }
        } else {
            FlowLayout {
                ForEach(Self.placeholderNames, id: \.self) { name in
                    Chip(name) {}
                }
            }
            .redacted(reason: .placeholder)
            .disabled(true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading genres")
        }
    }

    private static let placeholderNames = ["Ambient", "Jazz", "Post-punk", "Soul", "Electronic", "Folk", "Hip hop", "Classical", "Indie rock", "R&B"]

    /// The shared genre list (loaded once per launch), plus any chosen genre it doesn't include.
    private func loadGenres() async {
        genresError = nil
        let loaded: [GenreOption]
        do {
            loaded = try await GenreDirectory.shared.load(api: model.api)
        } catch is CancellationError {
            return
        } catch {
            // Offline: still offer the genres this device already knows.
            let known = Array(model.catalog.genres.values)
            guard !known.isEmpty else {
                genresError = (error as? APIError)?.errorDescription ?? "Genres couldn't load."
                return
            }
            loaded = await GenreOption.sorted(known)
        }
        let listed = Set(loaded.map(\.id))
        let missing = genreIds.filter { !listed.contains($0) }.compactMap { model.catalog.genres[$0] }
        genres = missing.isEmpty ? loaded : await GenreOption.sorted(loaded.map(\.genre) + missing)
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        // Only the chosen genres need to be in the catalog, so the profile can name them.
        let chosen = Set(genreIds)
        model.absorb(CatalogSlice(genres: (genres ?? []).map(\.genre).filter { chosen.contains($0.id) }))
        model.updateProfile(displayName: trimmedName, bio: trimmedBio, genreIds: genreIds)
        dismiss()
    }
}

/// The profile's genres as chips: chosen ones first, then the rest, filtered or a page
/// at a time. Its own view, so typing a name or bio never lays the chips out again.
private struct ProfileGenrePicker: View {
    @Binding var genreIds: [String]
    let options: [GenreOption]
    let limit: Int

    @State private var filter = ""
    @State private var showsAll = false

    private static let firstPage = 40

    var body: some View {
        let chosen = Set(genreIds)
        let query = TrackText.fold(filter)
        let selected = options.filter { chosen.contains($0.id) }
        let others = options.filter { !chosen.contains($0.id) && (query.isEmpty || $0.folded.contains(query)) }
        let shown = query.isEmpty && !showsAll ? Array(others.prefix(Self.firstPage)) : others
        VStack(alignment: .leading, spacing: RN.Space.m) {
            TextField("Find a genre", text: $filter)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            FlowLayout {
                ForEach(selected + shown) { option in
                    let isSelected = chosen.contains(option.id)
                    Chip(option.genre.name, isSelected: isSelected) { toggle(option.id) }
                        .disabled(!isSelected && genreIds.count >= limit)
                }
            }
            if query.isEmpty, others.count > Self.firstPage {
                Button(showsAll ? "Show fewer" : "Show all \(options.count) genres") { showsAll.toggle() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(RN.Palette.rustText)
            } else if !query.isEmpty, others.isEmpty {
                Text("No genre matches “\(filter)”.")
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
            }
        }
    }

    private func toggle(_ id: String) {
        if let index = genreIds.firstIndex(of: id) {
            genreIds.remove(at: index)
        } else if genreIds.count < limit {
            genreIds.append(id)
        }
    }
}

/// Edits the signed-in profile, for presenting through `Router.sheet`.
struct EditProfileHost: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let profile = model.profile {
            EditProfileSheet(profile: profile)
        }
    }
}
