import SwiftUI
import AppKit
import TranscriberCore

// MARK: - Чистый маппинг «настройки → конфиг ядра»

/// Режим языка распознавания в интерфейсе.
enum LanguageChoice: Int, CaseIterable, Identifiable {
    case auto = 0
    case russian = 1
    case english = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .auto: return L("settings.language.auto")
        case .russian: return L("settings.language.russian")
        case .english: return L("settings.language.english")
        }
    }

    /// Значение для `CoreConfig.language`.
    var language: LanguageMode {
        switch self {
        case .auto: return .auto
        case .russian: return .fixed(code: "ru")
        case .english: return .fixed(code: "en")
        }
    }

    /// Восстановление выбора из конфига (обратная операция).
    static func from(_ mode: LanguageMode) -> LanguageChoice {
        switch mode {
        case .auto, .candidates: return .auto
        case .fixed(let code):
            switch code.lowercased() {
            case "ru": return .russian
            case "en": return .english
            default: return .auto
            }
        }
    }
}

/// Чистые правила перевода значений из формы в `CoreConfig`.
///
/// Вынесено из вью, потому что здесь легко ошибиться (перевёрнутые границы
/// интервала, мусор в поле порта, пустой токен при включённом API), а проверить
/// это в SwiftUI-иерархии нечем. Все функции детерминированы и покрыты тестами.
enum SettingsMapping {
    /// Значения ползунков нарезки/VAD/языка → новый конфиг.
    ///
    /// `maxIntervalS` НИКОГДА не меньше `minIntervalS`: ядро с перевёрнутыми
    /// границами не режет интервалы вовсе. Отрицательные и нечисловые значения
    /// зажимаются в разумный диапазон.
    static func transcription(_ config: CoreConfig,
                              minS: Double, maxS: Double,
                              silenceMs: Double, vadThreshold: Double,
                              language: LanguageChoice) -> CoreConfig {
        var c = config
        let minValue = clampInt(minS, low: 10, high: 300)
        let maxValue = max(clampInt(maxS, low: 60, high: 600), minValue)
        c.minIntervalS = UInt32(minValue)
        c.maxIntervalS = UInt32(maxValue)
        c.silenceCutMs = UInt32(clampInt(silenceMs, low: 500, high: 5000))
        c.vad = VadConfig(sileroThreshold: Float(clamp(vadThreshold, low: 0.1, high: 0.9)),
                          rmsFallback: c.vad.rmsFallback)
        c.language = language.language
        return c
    }

    /// Срок хранения расшифровок → `CoreConfig.retentionDays`.
    ///
    /// Чистит базу само ядро (при `start()` и раз в сутки), поэтому значение
    /// достаточно записать в конфиг и применить `applyConfig` — оно
    /// подхватывается на лету. Отрицательные значения означают «хранить
    /// всегда»: удалить историю по испорченной настройке нельзя.
    static func retention(_ config: CoreConfig, days: Int) -> CoreConfig {
        var c = config
        c.retentionDays = Engine.retentionDays(days)
        return c
    }

    /// Настройки локального HTTP API.
    ///
    /// - порт разбирается терпимо: мусор и выход за диапазон → значение по
    ///   умолчанию, а не молчаливое отключение сервера;
    /// - при включении с пустым токеном он ГЕНЕРИРУЕТСЯ: включённый API без
    ///   токена — это открытый доступ к расшифровкам.
    static func api(_ config: CoreConfig,
                    enabled: Bool, host: String, port: String, token: String,
                    generateToken: () -> String = { randomToken() }) -> CoreConfig {
        var c = config
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        c.api = ApiConfig(enabled: enabled,
                          host: trimmedHost.isEmpty ? "127.0.0.1" : trimmedHost,
                          port: parsePort(port),
                          token: apiToken(enabled: enabled, current: token,
                                          generate: generateToken))
        return c
    }

    /// Порт из текстового поля; при любой некорректности — 8765.
    static func parsePort(_ text: String, fallback: UInt16 = 8765) -> UInt16 {
        guard let value = UInt16(text.trimmingCharacters(in: .whitespaces)), value > 0 else {
            return fallback
        }
        return value
    }

    /// Токен: сохраняем введённый, а при включении с пустым — генерируем.
    static func apiToken(enabled: Bool, current: String, generate: () -> String) -> String {
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if enabled && trimmed.isEmpty { return generate() }
        return trimmed
    }

    /// Случайный токен: `bytes * 2` шестнадцатеричных символов (по умолчанию 32).
    static func randomToken(bytes: Int = 16) -> String {
        (0..<max(1, bytes))
            .map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }
            .joined()
    }

    /// NaN не сравним ни с чем, поэтому обрабатывается отдельно (иначе
    /// `min`/`max` вернули бы NaN и `UInt32(NaN)` уронил бы процесс).
    /// Бесконечности зажимаются обычным образом.
    private static func clamp(_ v: Double, low: Double, high: Double) -> Double {
        guard !v.isNaN else { return low }
        return Swift.min(Swift.max(v, low), high)
    }
    private static func clampInt(_ v: Double, low: Double, high: Double) -> Int {
        Int(clamp(v, low: low, high: high).rounded())
    }
}

// MARK: - Раздел «Настройки»

/// Настройки: три секции — Основные · Журнал экрана · Дополнительно.
///
/// Всё, что нужно ежедневно, лежит сверху и не требует раскрытия; технические
/// параметры (нарезка интервалов, VAD, Ollama, локальный API, диагностика)
/// спрятаны под «Дополнительно».
struct SettingsPane: View {
    @ObservedObject var engine: Engine
    @ObservedObject var observer: ScreenObserver
    /// Открыть окно диагностики (реализовано в AppDelegate).
    var openDiagnostics: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("settings.title"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VisualEffectView(material: .headerView, blending: .withinWindow))
            Divider().overlay(Theme.Color.hairline)
            Form {
                GeneralSettings(engine: engine)
                ScreenSettings(observer: observer)
                AdvancedSettings(engine: engine, observer: observer,
                                 openDiagnostics: openDiagnostics)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .background(Theme.Color.bgBase)
    }
}

// MARK: - Основные

private struct GeneralSettings: View {
    @ObservedObject var engine: Engine
    @ObservedObject private var prefs = Prefs.shared
    @State private var launchAtLogin = LoginItem.shared.isEnabled
    @State private var loginError = ""
    @State private var language: LanguageChoice = .auto
    /// Сводка по хранилищу; `nil`, пока запрос не завершился или если он не
    /// удался (тогда строки просто нет).
    @State private var storeLine: String?

    var body: some View {
        Section(L("settings.general")) {
            Toggle(L("settings.general.launchAtLogin"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in setLaunch(on) }
            if !loginError.isEmpty {
                Text(loginError).font(.caption).foregroundStyle(Theme.Color.semWarning)
            }

            Picker(L("settings.general.language"), selection: $language) {
                ForEach(LanguageChoice.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: language) { _, _ in applyLanguage() }
            Text(L("settings.general.languageHint"))
                .font(.caption).foregroundStyle(Theme.Color.textTertiary)

            HStack {
                Button(L("settings.general.openDataFolder")) { openDataFolder() }
                    .accessibilityLabel(L("settings.general.openDataFolder.a11y"))
                Spacer(minLength: Theme.Space.s)
                if let storeLine {
                    Text(storeLine)
                        .font(.caption).foregroundStyle(Theme.Color.textTertiary)
                }
            }

            Text(AppInfo.versionLine)
                .font(.caption).foregroundStyle(Theme.Color.textTertiary)
        }
        .onAppear {
            launchAtLogin = LoginItem.shared.isEnabled
            language = LanguageChoice.from(engine.config.language)
        }
        // Размер базы и число записей читаются с диска — только асинхронно и
        // только при открытии раздела: в `body` такому запросу не место.
        .task { await loadStoreLine() }
    }

    /// Запрашивает сводку по хранилищу. Ошибка — молча `nil`.
    private func loadStoreLine() async {
        guard let info = await engine.storeInfoAsync() else { return }
        storeLine = Fmt.storeLine(sizeBytes: info.sizeBytes, walBytes: info.walBytes,
                                  intervals: info.intervals)
    }

    private func applyLanguage() {
        var c = engine.config
        c.language = language.language
        engine.applyConfig(c)
    }

    /// Открываем КАТАЛОГ данных приложения (родитель `store`), чтобы рядом
    /// были видны и модели, и журнал экрана.
    private func openDataFolder() {
        let url = URL(fileURLWithPath: engine.storagePath).deletingLastPathComponent()
        NSWorkspace.shared.open(url)
    }

    private func setLaunch(_ on: Bool) {
        do {
            try LoginItem.shared.setEnabled(on)
            loginError = ""
            prefs.launchAtLogin = on
        } catch {
            loginError = L("settings.general.launchFailed", error.localizedDescription)
            launchAtLogin = LoginItem.shared.isEnabled
        }
    }
}

// MARK: - Журнал экрана

/// Наблюдение экрана: периодический скриншот → локальная vision-модель через
/// Ollama → журнал «дел». Всё on-device; выключено по умолчанию.
private struct ScreenSettings: View {
    @ObservedObject var observer: ScreenObserver
    @ObservedObject private var prefs = Prefs.shared
    @State private var probe: VisionProbe?
    @State private var probing = false
    @State private var period: ScreenPeriodChoice = .oneMinute
    @State private var retention: ScreenRetentionChoice = .quarter

    var body: some View {
        Section(L("settings.screen")) {
            Toggle(L("settings.screen.observe"), isOn: $prefs.screenEnabled)
                .onChange(of: prefs.screenEnabled) {
                    if prefs.screenEnabled { observer.start() } else { observer.stop() }
                }
            Text(L("settings.screen.hint"))
                .font(.caption).foregroundStyle(Theme.Color.textTertiary)

            if prefs.screenEnabled {
                Picker(L("settings.screen.period"), selection: $period) {
                    ForEach(ScreenPeriodChoice.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: period) { _, v in prefs.screenPeriodS = v.seconds }

                Picker(L("settings.screen.retention"), selection: $retention) {
                    ForEach(ScreenRetentionChoice.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: retention) { _, v in prefs.screenRetentionDays = v.days }

                HStack {
                    Button(probing ? L("settings.screen.probing") : L("settings.screen.probe")) { runProbe() }
                        .disabled(probing)
                    Spacer(minLength: 0)
                }
                probeStatus
            }
        }
        .onAppear {
            period = ScreenPeriodChoice.nearest(toSeconds: prefs.screenPeriodS)
            retention = ScreenRetentionChoice.nearest(toDays: prefs.screenRetentionDays)
        }
    }

    private func runProbe() {
        probing = true
        Task {
            observer.rebuildDescriber()
            probe = await observer.probeBackend()
            probing = false
        }
    }

    @ViewBuilder private var probeStatus: some View {
        switch probe {
        case .none:
            EmptyView()
        case .ready:
            Label(L("settings.screen.probe.ready"), systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(Theme.Color.semSuccess)
        case .modelMissing(let hint):
            Label(L("settings.screen.probe.modelMissing", hint),
                  systemImage: "arrow.down.circle")
                .font(.caption).foregroundStyle(Theme.Color.semWarning)
                .textSelection(.enabled)
        case .unavailable:
            Label(L("settings.screen.probe.unavailable", prefs.visionModel),
                  systemImage: "xmark.circle")
                .font(.caption).foregroundStyle(Theme.Color.semWarning)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Дополнительно

/// Технические параметры: нарезка интервалов, VAD, адрес Ollama, локальный
/// HTTP API и окно диагностики. Свёрнуто по умолчанию.
private struct AdvancedSettings: View {
    @ObservedObject var engine: Engine
    @ObservedObject var observer: ScreenObserver
    let openDiagnostics: () -> Void
    @ObservedObject private var prefs = Prefs.shared

    @State private var expanded = false
    @State private var minInterval: Double = 30
    @State private var maxInterval: Double = 300
    @State private var silenceCut: Double = 2000
    @State private var vadThreshold: Double = 0.5

    @State private var retention: TranscriptRetentionChoice = .forever

    @State private var apiEnabled = false
    @State private var apiHost = "127.0.0.1"
    @State private var apiPort = "8765"
    @State private var apiToken = ""
    @State private var tokenCopied = false

    var body: some View {
        Section {
            DisclosureGroup(L("settings.advanced"), isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    intervalBlock
                    Divider().overlay(Theme.Color.hairline)
                    retentionBlock
                    Divider().overlay(Theme.Color.hairline)
                    visionBlock
                    Divider().overlay(Theme.Color.hairline)
                    apiBlock
                    Divider().overlay(Theme.Color.hairline)
                    Button(L("settings.advanced.diagnostics")) { openDiagnostics() }
                        .accessibilityLabel(L("settings.advanced.diagnostics.a11y"))
                }
                .padding(.top, Theme.Space.s)
            }
        }
        .onAppear(perform: load)
    }

    // MARK: нарезка + VAD

    private var intervalBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(L("settings.interval.section"))
            slider(L("settings.interval.min"), $minInterval, 10...300,
                   L("unit.seconds.short"), step: 5)
            slider(L("settings.interval.max"), $maxInterval, 60...600,
                   L("unit.seconds.short"), step: 10)
            slider(L("settings.interval.silence"), $silenceCut, 500...5000,
                   L("unit.milliseconds.short"), step: 100)
            vadSlider(L("settings.interval.vad"), $vadThreshold, 0.1...0.9, step: 0.05)
            Text(L("settings.interval.hint"))
                .font(.caption).foregroundStyle(Theme.Color.textTertiary)
        }
    }

    // MARK: срок хранения расшифровок

    private var retentionBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(L("settings.retention.section"))
            Picker(L("settings.retention.picker"), selection: $retention) {
                ForEach(TranscriptRetentionChoice.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: retention) { _, v in applyRetention(v) }
            Text(L("settings.retention.hint"))
                .font(.caption).foregroundStyle(Theme.Color.textTertiary)
        }
    }

    private func applyRetention(_ choice: TranscriptRetentionChoice) {
        prefs.transcriptRetentionDays = choice.days
        engine.applyConfig(SettingsMapping.retention(engine.config, days: choice.days))
    }

    // MARK: Ollama

    private var visionBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(L("settings.vision.section"))
            HStack {
                Text(L("settings.vision.ollamaURL"))
                TextField("http://127.0.0.1:11434", text: $prefs.ollamaURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { observer.rebuildDescriber() }
                    .accessibilityLabel(L("settings.vision.ollamaURL"))
            }
            HStack {
                Text(L("settings.vision.model"))
                TextField(Prefs.defaultVisionModel, text: $prefs.visionModel)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { observer.rebuildDescriber() }
                    .accessibilityLabel(L("settings.vision.model.a11y"))
            }
        }
    }

    // MARK: локальный API

    private var apiBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(L("settings.api.section"))
            Toggle(L("settings.api.enable"), isOn: $apiEnabled)
                .onChange(of: apiEnabled) { _, v in
                    engine.setApi(enabled: v)
                    persistApi()
                }
            TextField(L("settings.api.host"), text: $apiHost)
                .onSubmit(persistApi).disabled(!apiEnabled)
            TextField(L("settings.api.port"), text: $apiPort)
                .onSubmit(persistApi).disabled(!apiEnabled)
            HStack {
                TextField(L("settings.api.token"), text: $apiToken)
                    .onSubmit(persistApi).disabled(!apiEnabled)
                Button(tokenCopied ? L("settings.api.copied") : L("settings.api.copy")) { copyToken() }
                    .disabled(apiToken.isEmpty)
                    .accessibilityLabel(L("settings.api.copy.a11y"))
            }
            Text(L("settings.api.hint"))
                .font(.caption).foregroundStyle(Theme.Color.textTertiary)
            Text(L("settings.api.docs"))
                .font(.caption).foregroundStyle(Theme.Color.textTertiary)
                .textSelection(.enabled)
        }
    }

    private func copyToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(apiToken, forType: .string)
        tokenCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { tokenCopied = false }
    }

    // MARK: ползунки

    private func vadSlider(_ title: String, _ value: Binding<Double>,
                           _ range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.metric).foregroundStyle(Theme.Color.textSecondary)
            }
            Slider(value: value, in: range, step: step) { editing in if !editing { applyTranscription() } }
                .tint(Theme.Color.accent)
                .accessibilityLabel(title)
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        _ unit: String, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(unit)")
                    .font(.metric).foregroundStyle(Theme.Color.textSecondary)
            }
            Slider(value: value, in: range, step: step) { editing in if !editing { applyTranscription() } }
                .tint(Theme.Color.accent)
                .accessibilityLabel(title)
        }
    }

    // MARK: загрузка/сохранение

    private func load() {
        let c = engine.config
        minInterval = Double(c.minIntervalS)
        maxInterval = Double(c.maxIntervalS)
        silenceCut = Double(c.silenceCutMs)
        vadThreshold = Double(c.vad.sileroThreshold)
        apiEnabled = c.api.enabled
        apiHost = c.api.host
        apiPort = String(c.api.port)
        apiToken = c.api.token
        // Источник истины — настройка оболочки: конфиг ядра мог быть пересобран
        // из дефолтов, а выбор пользователя переживает перезапуск.
        retention = TranscriptRetentionChoice.nearest(toDays: prefs.transcriptRetentionDays)
    }

    private func applyTranscription() {
        engine.applyConfig(SettingsMapping.transcription(
            engine.config,
            minS: minInterval, maxS: maxInterval,
            silenceMs: silenceCut, vadThreshold: vadThreshold,
            language: LanguageChoice.from(engine.config.language)))
    }

    private func persistApi() {
        let updated = SettingsMapping.api(engine.config, enabled: apiEnabled,
                                          host: apiHost, port: apiPort, token: apiToken)
        // Сгенерированный токен показываем сразу — иначе пользователь не сможет
        // его скопировать и решит, что API открыт без авторизации.
        apiToken = updated.api.token
        apiHost = updated.api.host
        apiPort = String(updated.api.port)
        engine.applyConfig(updated)
    }
}
