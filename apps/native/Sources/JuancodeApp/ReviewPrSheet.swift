import SwiftUI
import JuancodeClient
import JuancodeCore

extension AppModel {
    /// Resolve a PR from its URL and open it in the full-width diff review, with the
    /// usual staged line comments. The PR is read and written by URL, so its repository
    /// needs no checkout here. Returns the reason it could not be opened, or nil.
    func reviewPr(at address: PrAddress) async -> String? {
        guard let reads = core.github else {
            return core.unavailableReason(.github) ?? "This core cannot read GitHub."
        }
        do {
            let pr = try await reads.pr(at: address)
            // The URL gh reports is the canonical one (owner and repo spelled as
            // GitHub spells them), which keeps the review's caches keyed one way.
            openPrDiffReview(pr, cwd: (PrAddress(parsing: pr.url) ?? address).cwd)
            return nil
        } catch let e as GitHubError {
            return e.message
        } catch {
            return error.localizedDescription
        }
    }
}

/// "Review PR": paste a GitHub pull-request URL, get its diff review.
struct ReviewPrSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var opening = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review a pull request").font(.system(size: 13, weight: .semibold))
            Text("Paste a GitHub PR URL. It opens in the diff review, in any repository, with or without a local checkout.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://github.com/owner/repo/pull/123", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .disabled(opening)
                .onSubmit(open)
                .onChange(of: text) { _, _ in error = nil }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                if opening { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).clickCursor()
                Button("Review", action: open)
                    .keyboardShortcut(.defaultAction)
                    .disabled(opening || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .clickCursor()
            }
        }
        .padding(16)
        .frame(width: 440)
        .onAppear { focused = true }
    }

    private func open() {
        guard !opening else { return }
        guard let address = PrAddress(parsing: text) else {
            error = "That is not a GitHub pull request URL (https://host/owner/repo/pull/123)."
            return
        }
        opening = true
        error = nil
        Task {
            let failure = await model.reviewPr(at: address)
            opening = false
            if let failure { error = failure } else { dismiss() }
        }
    }
}
