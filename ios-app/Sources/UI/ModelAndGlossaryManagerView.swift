import SwiftUI
import UniformTypeIdentifiers

// MARK: - Background-Safe GGUF Model Downloader

@MainActor
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var isDownloading: Bool = false
    @Published var progress: Double = 0
    @Published var activeFileName: String = ""
    @Published var errorMessage: String?

    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var destinationURL: URL?
    private var onComplete: ((URL) -> Void)?

    func startDownload(from urlString: String, to destination: URL, onComplete: @escaping (URL) -> Void) {
        guard let url = URL(string: urlString) else {
            errorMessage = "رابط التحميل غير صالح"
            return
        }
        cancel()
        self.destinationURL = destination
        self.onComplete = onComplete
        self.activeFileName = destination.lastPathComponent
        self.progress = 0
        self.errorMessage = nil
        self.isDownloading = true

        let config = URLSessionConfiguration.default
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = s
        let task = s.downloadTask(with: url)
        self.downloadTask = task
        task.resume()
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        session?.invalidateAndCancel()
        session = nil
        isDownloading = false
        progress = 0
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let pct = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            self.progress = pct
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Must move temp file synchronously before this delegate callback returns
        let tempCopy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        do {
            try FileManager.default.moveItem(at: location, to: tempCopy)
            Task { @MainActor in
                guard let dest = self.destinationURL else {
                    try? FileManager.default.removeItem(at: tempCopy)
                    self.isDownloading = false
                    return
                }
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.moveItem(at: tempCopy, to: dest)
                    self.isDownloading = false
                    self.progress = 1.0
                    self.onComplete?(dest)
                } catch {
                    try? FileManager.default.removeItem(at: tempCopy)
                    self.errorMessage = "فشل حفظ النموذج: \(error.localizedDescription)"
                    self.isDownloading = false
                }
            }
        } catch {
            Task { @MainActor in
                self.errorMessage = "فشل نقل ملف التحميل: \(error.localizedDescription)"
                self.isDownloading = false
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsErr = error as NSError
        if nsErr.code == NSURLErrorCancelled { return }
        Task { @MainActor in
            self.errorMessage = "تعذر التحميل: \(error.localizedDescription)"
            self.isDownloading = false
        }
    }
}

// MARK: - Model & Glossary Manager View

public struct ModelAndGlossaryManagerView: View {

    @ObservedObject var engine: TranslationEngine
    @StateObject private var downloader = ModelDownloader()

    @State private var installedModels: [URL] = []
    @State private var showFileImporter: Bool = false

    @State private var selectedTitleID: String = "GLOBAL"
    @State private var glossaryTerms: [String: String] = [:]
    @State private var newEnglishTerm: String = ""
    @State private var newArabicTerm: String = ""
    @State private var importError: String?

    public init(engine: TranslationEngine) {
        self.engine = engine
    }

    public var body: some View {
        NavigationStack {
            Form {
                // 1. Mode & Preset Downloads
                Section("وضع الترجمة وتحميل النماذج (مرة واحدة ثم أوفلاين)") {
                    Picker("نمط الأداء", selection: $engine.qualityMode) {
                        ForEach(TranslationQualityMode.allCases) { mode in
                            Text(mode.arabicTitle).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    ForEach(TranslationQualityMode.allCases) { mode in
                        let targetURL = engine.modelsDirectory.appendingPathComponent(mode.recommendedFileName)
                        let exists = FileManager.default.fileExists(atPath: targetURL.path)

                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode.arabicTitle)
                                    .font(.subheadline.bold())
                                Text(mode.recommendedFileName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if exists {
                                Button(engine.loadedModelName == mode.recommendedFileName && engine.isModelLoaded ? "مفعّل" : "تشغيل") {
                                    Task { await engine.loadModelFile(at: targetURL) }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(engine.loadedModelName == mode.recommendedFileName && engine.isModelLoaded ? .green : .blue)
                                .disabled(engine.isLoadingModel)
                            } else {
                                Button("تحميل") {
                                    downloader.startDownload(from: mode.downloadURLString, to: targetURL) { savedURL in
                                        refreshModels()
                                        Task { await engine.loadModelFile(at: savedURL) }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(downloader.isDownloading)
                            }
                        }
                    }

                    if downloader.isDownloading {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("جاري تحميل \(downloader.activeFileName)...")
                                    .font(.caption)
                                Spacer()
                                Text("\(Int(downloader.progress * 100))%")
                                    .font(.caption.monospacedDigit())
                            }
                            ProgressView(value: downloader.progress)
                            Button("إلغاء التحميل", role: .destructive) {
                                downloader.cancel()
                            }
                            .font(.caption)
                        }
                    }

                    if let err = downloader.errorMessage ?? importError {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    Button {
                        showFileImporter = true
                    } label: {
                        Label("استيراد ملف GGUF من تطبيق الملفات", systemImage: "folder.badge.plus")
                    }
                }

                // 2. Installed Models
                if !installedModels.isEmpty {
                    Section("النماذج المحفوظة على الآيفون") {
                        ForEach(installedModels, id: \.path) { fileURL in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(fileURL.lastPathComponent)
                                        .font(.caption.bold())
                                    Text(formattedFileSize(fileURL))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if engine.loadedModelName == fileURL.lastPathComponent && engine.isModelLoaded {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                } else {
                                    Button("تحميل") {
                                        Task { await engine.loadModelFile(at: fileURL) }
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                }
                            }
                            .swipeActions {
                                Button("حذف", role: .destructive) {
                                    try? FileManager.default.removeItem(at: fileURL)
                                    refreshModels()
                                }
                            }
                        }
                    }
                }

                // 3. Per-Game Glossary Editor
                Section("قاموس المصطلحات الخاص باللعبة") {
                    HStack {
                        Text("معرّف اللعبة (Title ID):")
                            .font(.caption)
                        TextField("مثال: PPSA01234", text: $selectedTitleID)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.leading)
                            .onSubmit {
                                Task { await reloadGlossary() }
                            }
                        Button("تحديث") {
                            Task { await reloadGlossary() }
                        }
                        .font(.caption)
                    }

                    HStack(spacing: 8) {
                        TextField("المصطلح بالإنجليزية", text: $newEnglishTerm)
                            .autocorrectionDisabled()
                        TextField("الترجمة العربية", text: $newArabicTerm)
                        Button {
                            let en = newEnglishTerm
                            let ar = newArabicTerm
                            newEnglishTerm = ""
                            newArabicTerm = ""
                            Task {
                                await engine.cache.upsertGlossaryTerm(english: en, arabic: ar, for: selectedTitleID)
                                await reloadGlossary()
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                        }
                        .disabled(newEnglishTerm.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  newArabicTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if glossaryTerms.isEmpty {
                        Text("لا توجد مصطلحات مخصصة لهذه اللعبة بعد.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(glossaryTerms.keys.sorted(), id: \.self) { key in
                            HStack {
                                Text(key)
                                    .font(.subheadline.monospaced())
                                Spacer()
                                Text(glossaryTerms[key] ?? "")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.mint)
                            }
                            .swipeActions {
                                Button("حذف", role: .destructive) {
                                    Task {
                                        await engine.cache.removeGlossaryTerm(english: key, for: selectedTitleID)
                                        await reloadGlossary()
                                    }
                                }
                            }
                        }
                    }
                }

                // 4. SQLite Cache Management
                Section("ذاكرة الترجمة السريعة (SQLite Cache)") {
                    HStack {
                        Text("الجمل المحفوظة للترجمة الفورية")
                        Spacer()
                        Text("\(engine.cachedEntriesCount)")
                            .font(.headline.monospacedDigit())
                    }
                    Button("مسح ذاكرة الكاش بالكامل", role: .destructive) {
                        Task {
                            await engine.cache.clearCache()
                            await engine.translator.clearRollingContext()
                            await engine.refreshCacheCount()
                        }
                    }
                }
            }
            .navigationTitle("النماذج والقاموس")
            .onAppear {
                selectedTitleID = engine.activeTitleID
                refreshModels()
                Task {
                    await reloadGlossary()
                    await engine.refreshCacheCount()
                }
            }
            .onChange(of: engine.activeTitleID) { _, newID in
                selectedTitleID = newID
                Task { await reloadGlossary() }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                handleImportedFile(result)
            }
        }
    }

    private func refreshModels() {
        installedModels = engine.listInstalledModelURLs()
    }

    private func reloadGlossary() async {
        glossaryTerms = await engine.cache.loadGlossary(for: selectedTitleID)
    }

    private func handleImportedFile(_ result: Result<[URL], Error>) {
        importError = nil
        switch result {
        case .success(let urls):
            guard let src = urls.first else { return }
            let access = src.startAccessingSecurityScopedResource()
            defer { if access { src.stopAccessingSecurityScopedResource() } }

            let dest = engine.modelsDirectory.appendingPathComponent(src.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: src, to: dest)
                refreshModels()
                Task { await engine.loadModelFile(at: dest) }
            } catch {
                importError = "فشل استيراد الملف: \(error.localizedDescription)"
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func formattedFileSize(_ url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
