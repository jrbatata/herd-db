import AppKit
import Foundation

/// Verifica as releases oficiais do Herd, baixa o .zip publicado e troca o app
/// instalado, reabrindo em seguida. Nada de baixar instalador na mão.
@MainActor
final class UpdateController {
    static let shared = UpdateController()

    private let latestReleaseURL = URL(string: "https://api.github.com/repos/jrbatata/herd-db/releases/latest")!
    private var startupCheckStarted = false
    private var checkInProgress = false
    private var progressPanel: UpdateProgressPanel?

    private init() {}

    func checkAtLaunch() {
        guard !startupCheckStarted else { return }
        startupCheckStarted = true

        Task {
            // Deixa a primeira janela terminar de aparecer antes de apresentar um alerta.
            try? await Task.sleep(for: .seconds(1.5))
            await checkForUpdates(userInitiated: false)
        }
    }

    func checkManually() {
        Task { await checkForUpdates(userInitiated: true) }
    }

    private func checkForUpdates(userInitiated: Bool) async {
        guard !checkInProgress else { return }
        checkInProgress = true
        defer { checkInProgress = false }

        do {
            let release = try await fetchLatestRelease()
            let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

            guard Version(release.version) > Version(currentVersion) else {
                if userInitiated {
                    showInformation(
                        title: "O Herd está atualizado",
                        message: "Você já está usando a versão mais recente (\(currentVersion))."
                    )
                }
                return
            }

            showAvailableUpdate(release, currentVersion: currentVersion)
        } catch UpdateError.noPublishedRelease {
            if userInitiated {
                showInformation(
                    title: "Nenhuma atualização publicada",
                    message: "Ainda não há uma release pública disponível para atualização."
                )
            }
        } catch {
            // Uma falha de rede ao abrir o app não deve interromper o trabalho.
            if userInitiated {
                showInformation(
                    title: "Não foi possível verificar atualizações",
                    message: "Confira sua conexão com a internet e tente novamente."
                )
            }
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: latestReleaseURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("herd-db-update-checker", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }
        if http.statusCode == 404 { throw UpdateError.noPublishedRelease }
        guard (200..<300).contains(http.statusCode) else { throw UpdateError.invalidResponse }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func showAvailableUpdate(_ release: GitHubRelease, currentVersion: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Uma nova versão do Herd está disponível"

        var details = "Versão instalada: \(currentVersion)\nNova versão: \(release.version)"
        if let notes = changelogSummary(from: release.notes) {
            details += "\n\n" + notes
        }

        // Só oferece a troca automática quando o app está num lugar onde dá para gravar.
        if release.archiveURL != nil, canReplaceCurrentApp {
            details += "\n\nO Herd baixa a atualização, substitui o app e reabre sozinho. Suas conexões e senhas são preservadas."
            alert.informativeText = details
            alert.addButton(withTitle: "Atualizar agora")
            alert.addButton(withTitle: "Agora não")

            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Task { await install(release) }
        } else {
            details += "\n\nBaixe o .dmg, abra-o e substitua o Herd na pasta Aplicativos. Suas conexões e senhas serão preservadas."
            alert.informativeText = details
            alert.addButton(withTitle: "Baixar atualização")
            alert.addButton(withTitle: "Agora não")

            guard alert.runModal() == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.open(release.preferredDownloadURL)
        }
    }

    /// O app precisa estar num bundle `.app` cuja pasta permita escrita.
    private var canReplaceCurrentApp: Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return false }
        return FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
    }

    private func install(_ release: GitHubRelease) async {
        guard let archiveURL = release.archiveURL else { return }

        let panel = UpdateProgressPanel(
            title: "Atualizando o Herd",
            message: "Baixando a versão \(release.version)…"
        )
        progressPanel = panel
        panel.show()

        do {
            let zip = try await download(archiveURL, panel: panel)
            panel.set(message: "Preparando a instalação…", progress: nil)
            let stagedApp = try await extract(zip, expecting: release.version)
            panel.set(message: "Instalando e reabrindo…", progress: 1)
            try launchReplacement(stagedApp: stagedApp)
            panel.close()
            progressPanel = nil
            NSApp.terminate(nil)
        } catch {
            progressPanel?.close()
            progressPanel = nil
            showInstallFailure(error, release: release)
        }
    }

    private func download(_ url: URL, panel: UpdateProgressPanel) async throws -> URL {
        let delegate = DownloadProgressDelegate { value in
            panel.set(progress: value)
        }
        let (temporary, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.downloadFailed
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("herd-\(UUID().uuidString).zip")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private func extract(_ zip: URL, expecting version: String) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await runProcess("/usr/bin/ditto", ["-x", "-k", "--sequesterRsrc", zip.path, directory.path])

        let apps = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }

        guard let app = apps.first,
              let info = Bundle(url: app)?.infoDictionary,
              let identifier = info["CFBundleIdentifier"] as? String,
              identifier == Bundle.main.bundleIdentifier,
              let downloaded = info["CFBundleShortVersionString"] as? String,
              downloaded == version
        else { throw UpdateError.invalidArchive }

        return app
    }

    /// Deixa um script de pé para trocar o bundle depois que este processo sair.
    private func launchReplacement(stagedApp: URL) throws {
        let target = Bundle.main.bundlePath
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("herd-update-\(UUID().uuidString).sh")

        let pid = ProcessInfo.processInfo.processIdentifier
        let contents = """
        #!/bin/sh
        # Espera o Herd atual encerrar, troca o bundle e reabre.
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done

        target="$1"
        staged="$2"
        backup="${target}.old"

        /bin/rm -rf "$backup"
        /bin/mv "$target" "$backup" || exit 1

        if /usr/bin/ditto "$staged" "$target"; then
            /bin/rm -rf "$backup"
            /bin/rm -rf "$(dirname "$staged")"
        else
            /bin/rm -rf "$target"
            /bin/mv "$backup" "$target"
            exit 1
        fi

        /usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null || true
        /usr/bin/open "$target"
        """

        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, target, stagedApp.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private func runProcess(_ executable: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError.extractionFailed)
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func showInstallFailure(_ error: Error, release: GitHubRelease) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Não foi possível instalar a atualização"
        alert.informativeText = "\(error.localizedDescription)\n\nVocê ainda pode baixar o .dmg manualmente."
        alert.addButton(withTitle: "Abrir página de download")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.preferredDownloadURL)
        }
    }

    /// Tira o "Full Changelog" cru do GitHub, que só polui o alerta.
    private func changelogSummary(from notes: String?) -> String? {
        guard let notes else { return nil }
        let cleaned = notes
            .split(separator: "\n")
            .filter { !$0.localizedCaseInsensitiveContains("full changelog") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(400))
    }

    private func showInformation(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

@MainActor
private final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in self.onProgress(value) }
    }
}

@MainActor
private final class UpdateProgressPanel {
    private let window: NSPanel
    private let label: NSTextField
    private let bar: NSProgressIndicator

    init(title: String, message: String) {
        label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12)

        bar = NSProgressIndicator()
        bar.style = .bar
        bar.controlSize = .small
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0

        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            bar.widthAnchor.constraint(equalToConstant: 320),
        ])

        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 76),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.level = .modalPanel
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func set(message: String? = nil, progress: Double?) {
        if let message { label.stringValue = message }
        if let progress {
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
            bar.doubleValue = progress
        } else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
    }

    func close() {
        bar.stopAnimation(nil)
        window.close()
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let downloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let pageURL: URL
    let notes: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case pageURL = "html_url"
        case notes = "body"
        case assets
    }

    var version: String {
        tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    /// Preferimos o .zip: extrai com `ditto` sem montar o .dmg.
    var archiveURL: URL? {
        assets.first { $0.name.lowercased().hasSuffix(".zip") }?.downloadURL
    }

    var preferredDownloadURL: URL {
        assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.downloadURL ?? pageURL
    }
}

private struct Version: Comparable {
    private let components: [Int]

    init(_ value: String) {
        let core = value.split(separator: "-", maxSplits: 1).first ?? ""
        components = core.split(separator: ".").map { component in
            Int(component.prefix { $0.isNumber }) ?? 0
        }
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

private enum UpdateError: LocalizedError {
    case noPublishedRelease
    case invalidResponse
    case downloadFailed
    case invalidArchive
    case extractionFailed

    var errorDescription: String? {
        switch self {
        case .noPublishedRelease: "Ainda não há uma release pública disponível."
        case .invalidResponse: "O GitHub não retornou uma release válida."
        case .downloadFailed: "O download da atualização falhou."
        case .invalidArchive: "O arquivo baixado não contém o app esperado."
        case .extractionFailed: "Não foi possível descompactar a atualização."
        }
    }
}
