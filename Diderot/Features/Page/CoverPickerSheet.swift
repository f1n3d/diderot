import SwiftUI
import PhotosUI
import DocmostKit

/// "Change Cover", as the web's picker: the gallery of presets (colors, gradients, textures) and an upload. A preset
/// becomes the cover when tapped, with the band showing it above the half-high sheet; an uploaded image once it is on
/// the server, and the picker closes. An upload the picker opened with can be taken back ("Uploaded"): the server keeps
/// a replaced one for an hour. Unsplash photos stay on the web, whose search needs the server's key.
struct CoverPickerSheet: View {
    let page: Page
    let edit: PageCoverEdit
    let actions: PageCoverActions
    /// The cover when the picker opened.
    let opened: PageCoverEdit.Fields

    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.gallery
    @State private var showsPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showsCamera = false
    @State private var showsFileImporter = false

    private enum Tab: Hashable {
        case gallery, upload
    }

    private var fields: PageCoverEdit.Fields { edit.fields(of: page) }

    var body: some View {
        NavigationStack {
            ScrollView {
                switch tab {
                case .gallery: gallery
                case .upload: upload
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Change Cover", selection: $tab) {
                    Text("Gallery").tag(Tab.gallery)
                    Text("Upload").tag(Tab.upload)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .accessibilityIdentifier("cover-picker-tabs")
            }
            .navigationTitle("Change Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("cover-picker-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .photosPicker(isPresented: $showsPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            upload { try await CoverImage.file(from: item) }
        }
        .linkFullScreenCover(isPresented: $showsCamera) {
            CameraPicker { data in upload { try await CoverImage.file(from: data, name: nil) } }
                .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url): upload { try await CoverImage.file(at: url) }
            case .failure(let error): actions.report(error.userMessage)
            }
        }
    }

    // MARK: - Gallery

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 18) {
            if case .file(let path) = PageCover(opened.photo) {
                section("Uploaded", columns: Self.pictureColumns) {
                    CoverTile(label: Text("Uploaded image"), selected: fields.photo == opened.photo, aspectRatio: 2) {
                        UploadedCoverThumbnail(path: path)
                    } pick: {
                        pick(.photo(opened.photo, position: opened.position))
                    }
                    .accessibilityIdentifier("cover-uploaded")
                }
            }
            section("Colors", columns: Self.colorColumns) { tiles(CoverPreset.colors, aspectRatio: 5.0 / 3) }
            section("Gradients", columns: Self.pictureColumns) { tiles(CoverPreset.gradients, aspectRatio: 2) }
            section("Textures", columns: Self.pictureColumns) { tiles(CoverPreset.textures, aspectRatio: 2) }
        }
        .padding()
    }

    private static let colorColumns = [GridItem(.adaptive(minimum: 72), spacing: 8)]
    private static let pictureColumns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    private func section(_ title: LocalizedStringKey, columns: [GridItem], @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: 8, content: content)
        }
    }

    private func tiles(_ presets: [CoverPreset], aspectRatio: CGFloat) -> some View {
        ForEach(presets) { preset in
            CoverTile(label: Text(preset.label), selected: fields.photo == preset.value, aspectRatio: aspectRatio) {
                // As the web's tiles: the picture's middle.
                if preset.kind == .color {
                    CoverArt(preset: preset)
                } else {
                    CoverFit(natural: CoverPreset.pictureSize, position: 50) { CoverArt(preset: preset) }
                }
            } pick: {
                pick(.photo(preset.value))
            }
            .accessibilityIdentifier("cover-preset-\(preset.id)")
        }
    }

    private func pick(_ change: PageCoverEdit.Change) {
        guard case .photo(let photo, _) = change, photo != fields.photo else { return }
        edit.send(change, shown: fields, with: actions)
    }

    // MARK: - Upload

    private var upload: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if edit.isUploading {
                ProgressView("Uploading…")
            } else {
                Menu {
                    Button("Photo Library", systemImage: "photo.on.rectangle") { showsPhotoPicker = true }
                    if CameraPicker.isAvailable {
                        Button("Take Photo", systemImage: "camera") { showsCamera = true }
                    }
                    Button("Choose File", systemImage: "folder") { showsFileImporter = true }
                } label: {
                    Text("Upload Image")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("cover-upload")
            }
            Text("Use an image at least 1200 pixels wide.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 180)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .padding()
    }

    /// Converts and uploads the picked image (`PageCoverEdit.upload`); the picker closes once it is the cover.
    private func upload(_ prepare: @escaping @Sendable () async throws -> CoverImage.File?) {
        let shown = fields
        Task {
            if await edit.upload(prepare, shown: shown, with: actions) { dismiss() }
        }
    }
}

/// A cover in the picker: the picture, ringed and ticked when it is the page's.
private struct CoverTile<Content: View>: View {
    let label: Text
    let selected: Bool
    let aspectRatio: CGFloat
    @ViewBuilder let content: Content
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            Color(.secondarySystemFill)
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay { content }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.08)) }
                .padding(3)
                .overlay {
                    if selected { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 2) }
                }
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.footnote)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(6)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The upload the picker opened with, small.
private struct UploadedCoverThumbnail: View {
    let path: String
    @Environment(\.renderContext) private var context
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image { ResizableImage(image: image).scaledToFill() }
            }
            .task(id: path) {
                guard let url = context.baseURL.flatMap({ ImageURL.resolveContentMedia(path, baseURL: $0) }),
                      let loader = context.mediaLoader
                else { return }
                image = try? await loader.image(for: url, targetWidth: 200, scale: displayScale, maxBytes: MediaLoader.maxAutomaticBytes)
            }
    }
}
