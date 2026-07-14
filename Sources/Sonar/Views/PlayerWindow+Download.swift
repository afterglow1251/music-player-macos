import SwiftUI
import AppKit

extension PlayerWindow {
    // MARK: Error toast

    @ViewBuilder private var errorToast: some View {
        if let error = controller.downloader.lastError {
            Text(error)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Capsule().fill(Color.red.opacity(0.85)))
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: error) {
                    try? await Task.sleep(for: .seconds(4))
                    controller.downloader.lastError = nil
                }
        }
    }

    /// A neutral, accent-coloured info toast (e.g. "Already in library") — the
    /// non-error sibling of `errorToast`.
    @ViewBuilder private var noticeToast: some View {
        if let notice = controller.downloader.notice {
            Text(notice)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.black)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Capsule().fill(accent.opacity(0.9)))
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(2.5))
                    controller.downloader.notice = nil
                }
        }
    }

    /// Both transient toasts, stacked at the bottom of the window.
    @ViewBuilder var bottomToasts: some View {
        VStack(spacing: 8) {
            noticeToast
            errorToast
        }
        .animation(.easeInOut(duration: 0.25), value: controller.downloader.notice)
        .animation(.easeInOut(duration: 0.25), value: controller.downloader.lastError)
    }

    // MARK: Drag & drop

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let urlProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        if !urlProviders.isEmpty {
            Task { @MainActor in
                var files: [URL] = []
                for provider in urlProviders {
                    guard let url = await loadURL(from: provider) else { continue }
                    if url.isFileURL { files.append(url) }
                    else { controller.download(url.absoluteString) }   // a dragged link
                }
                // Import every dropped file at once — added to the library with an
                // "Added" toast, without hijacking playback (same as a download).
                controller.importFiles(files)
            }
            return true
        }

        // Fallback: a dragged plain-text http link (no URL object).
        for provider in providers {
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                guard let text = string as? String, text.contains("http") else { return }
                Task { @MainActor in controller.download(text) }
            }
        }
        return true
    }

    /// Await an `NSItemProvider`'s URL (wraps the callback-based load API).
    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}
