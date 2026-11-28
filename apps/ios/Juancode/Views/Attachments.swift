import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Files picked on the phone, uploaded to the Mac as soon as they are picked. `paths` are the
/// Mac paths that go into the outgoing message, as the desktop's drag-and-drop types them.
@MainActor @Observable
final class Attachments {
    struct Item: Identifiable {
        let id = UUID()
        let name: String
        var path: String?
    }
    private(set) var items: [Item] = []
    var error: String?

    var busy: Bool { items.contains { $0.path == nil } }
    var paths: [String] { items.compactMap(\.path) }

    /// `text` with every uploaded path appended, then the list cleared.
    func take(into text: String) -> String {
        let all = ([text] + paths).filter { !$0.isEmpty }.joined(separator: " ")
        items = []
        return all
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    func add(_ data: Data, name: String, client: SidecarClient) {
        error = nil
        let item = Item(name: name)
        items.append(item)
        Task {
            do {
                let path = try await client.upload(data, name: name)
                if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].path = path }
            } catch {
                self.error = error.localizedDescription
                remove(item.id)
            }
        }
    }
}

/// Paperclip menu (photo library or Files), or a + menu that also offers voice when `voice` is
/// given. Needs no usage strings: PhotosPicker and the file importer run out of process.
struct AttachButton: View {
    let attachments: Attachments
    let client: SidecarClient
    var voice: (() -> Void)?
    @State private var photos: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false

    var body: some View {
        Menu {
            Button { showPhotos = true } label: { Label("Photo Library", systemImage: "photo") }
            Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
            if let voice { Button(action: voice) { Label("Voice", systemImage: "mic") } }
        } label: {
            Image(systemName: voice == nil ? "paperclip" : "plus").composerIcon()
        }
        .accessibilityLabel("Attach")
        .photosPicker(isPresented: $showPhotos, selection: $photos, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls):
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do { attachments.add(try Data(contentsOf: url), name: url.lastPathComponent, client: client) }
                    catch { attachments.error = error.localizedDescription }
                }
            case let .failure(error): attachments.error = error.localizedDescription
            }
        }
        .onChange(of: photos) { _, picked in
            guard !picked.isEmpty else { return }
            photos = []
            for (n, item) in picked.enumerated() {
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self) else {
                        attachments.error = "Could not read that item."
                        return
                    }
                    let stamp = "\(Int(Date().timeIntervalSince1970))-\(n)"
                    // HEIC is what the camera roll holds and agents cannot read it: send images as JPEG.
                    if item.supportedContentTypes.contains(where: { $0.conforms(to: .image) }),
                       let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) {
                        attachments.add(jpeg, name: "photo-\(stamp).jpg", client: client)
                    } else {
                        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "bin"
                        attachments.add(data, name: "media-\(stamp).\(ext)", client: client)
                    }
                }
            }
        }
    }
}

/// The pending attachments above a composer; tap the x to drop one.
struct AttachmentChips: View {
    let attachments: Attachments

    var body: some View {
        if !attachments.items.isEmpty || attachments.error != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let error = attachments.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(attachments.items) { item in
                            HStack(spacing: 4) {
                                if item.path == nil { ProgressView().controlSize(.mini) }
                                Text(item.name).font(.caption).lineLimit(1)
                                Button { attachments.remove(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                                    .accessibilityLabel("Remove \(item.name)")
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }
}

// MARK: Composer chrome shared by the session and Oracle input bars.

extension View {
    /// 40pt tap target for a bare glyph (attach, mic).
    func composerIcon() -> some View {
        font(.system(size: 20, weight: .medium)).frame(width: 40, height: 40).contentShape(Rectangle())
    }

    func composerField() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Tok.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Tok.surface2))
    }
}

struct SendButton: View {
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(disabled ? Tok.surface2 : Tok.blue, in: Circle())
        }
        .disabled(disabled)
        .accessibilityLabel("Send")
        .animation(.snappy, value: disabled)
    }
}
