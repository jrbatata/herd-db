import AppKit
import Foundation

/// Verifica as releases oficiais do Herd e conduz o usuário até o instalador mais recente.
@MainActor
final class UpdateController {
    static let shared = UpdateController()

    private let latestReleaseURL = URL(string: "https://api.github.com/repos/jrbatata/herd-db/releases/latest")!
    private var startupCheckStarted = false
    private var checkInProgress = false

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
        if let notes = release.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            details += "\n\n" + String(notes.prefix(700))
        }
        details += "\n\nBaixe o .dmg, abra-o e substitua o Herd na pasta Aplicativos. Suas conexões e senhas serão preservadas."
        alert.informativeText = details
        alert.addButton(withTitle: "Baixar atualização")
        alert.addButton(withTitle: "Agora não")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(release.preferredDownloadURL)
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

    var errorDescription: String? {
        switch self {
        case .noPublishedRelease: "Ainda não há uma release pública disponível."
        case .invalidResponse: "O GitHub não retornou uma release válida."
        }
    }
}
