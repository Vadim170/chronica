import SwiftUI
import TranscriberCore

// MARK: - Каталог моделей для интерфейса

/// Человекочитаемая витрина реестра моделей ядра.
///
/// В реестре 30+ вариантов Whisper: показывать их все плоским списком —
/// значит утопить единственную нужную строку. Здесь решается, ЧТО видно
/// сразу, а что прячется под «Все варианты Whisper». Правила чистые и
/// покрыты тестами: реестр в тестах подставляется вручную.
enum ModelCatalog {
    /// Разумный набор вариантов Whisper для плоского списка.
    /// Порядок — от «лучше качество» к «меньше размер».
    static let featuredWhisper = [
        "large-v3-turbo-q5_0",
        "large-v3-turbo",
        "medium-q5_0",
        "small-q5_1",
        "base-q5_1",
    ]

    /// Сколько языков понимает каждое семейство (для подписи строки модели).
    static let parakeetLanguages = 25
    static let whisperLanguages = 99

    /// Короткое имя модели для кнопок и подсказок вне списка.
    static func displayName(id: String) -> String {
        id.lowercased().hasPrefix("parakeet") ? "Parakeet" : L("models.name.whisper", id)
    }

    /// Примерный размер загрузки — для честного предупреждения ДО скачивания.
    ///
    /// У Parakeet (модель по умолчанию) размер известен заранее. Для остальных
    /// точный размер отдаёт реестр после запроса к HuggingFace, поэтому здесь
    /// честное «размер уточняется», а не выдуманное «≈1 ГБ».
    static func approximateSize(id: String) -> String {
        id.lowercased().hasPrefix("parakeet")
            ? L("models.size.parakeet")
            : L("models.size.unknown")
    }

    /// Языки семейства — вместо имени рантайма, которое ничего не говорит.
    static func languages(family: String) -> String {
        family.lowercased().contains("parakeet")
            ? L("models.languages.parakeet", parakeetLanguages)
            : L("models.languages.whisper", whisperLanguages)
    }

    /// Служебная модель Silero VAD едет вместе с любой ASR-моделью и выбору
    /// пользователя не подлежит. Ядро уже прячет её из `listModels()`, но
    /// витрина не должна зависеть от этого: одна «модель», которую нельзя
    /// выбрать, ломает весь смысл списка.
    static func isTranscriptionModel(_ m: ModelStatus) -> Bool {
        m.id.lowercased() != "silero-vad" && m.family.lowercased() != "vad"
    }

    /// Плоский список: сначала все Parakeet, затем избранные варианты Whisper.
    ///
    /// Модель НИКОГДА не пропадает из основного списка, если она активная,
    /// выбранная к применению, установлена или прямо сейчас скачивается —
    /// иначе её нельзя было бы найти, чтобы удалить или переключиться.
    static func primary(_ models: [ModelStatus],
                        activeId: String,
                        pendingId: String?) -> [ModelStatus] {
        let models = models.filter(isTranscriptionModel)
        let parakeet = models.filter { $0.family.lowercased().contains("parakeet") }
        let whisper = models.filter { !$0.family.lowercased().contains("parakeet") }
        let featured = featuredWhisper.compactMap { id in whisper.first { $0.id == id } }
        let featuredIds = Set(featured.map(\.id))
        let pinned = whisper.filter {
            !featuredIds.contains($0.id) && isPinned($0, activeId: activeId, pendingId: pendingId)
        }
        return parakeet + featured + pinned
    }

    /// Остальные варианты Whisper — под раскрывающимся списком.
    static func extraWhisper(_ models: [ModelStatus],
                             activeId: String,
                             pendingId: String?) -> [ModelStatus] {
        let shown = Set(primary(models, activeId: activeId, pendingId: pendingId).map(\.id))
        return models.filter {
            isTranscriptionModel($0)
                && !$0.family.lowercased().contains("parakeet")
                && !shown.contains($0.id)
        }
    }

    private static func isPinned(_ m: ModelStatus, activeId: String, pendingId: String?) -> Bool {
        m.id == activeId || m.id == pendingId || m.installed || m.downloading
    }
}

// MARK: - Раздел «Модели»

/// Раздел «Модели»: плоский список без выбора «движка» и без имён рантаймов.
///
/// Смена модели — это перезапуск сессии, поэтому выбор лишь «ставится в
/// очередь» (`Engine.stageModel`), а применяется кнопкой в баннере.
struct ModelsView: View {
    @ObservedObject var engine: Engine
    @State private var showAllWhisper = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("models.title"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VisualEffectView(material: .headerView, blending: .withinWindow))
            Divider().overlay(Theme.Color.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    applyBanner
                    if engine.models.isEmpty {
                        ContentUnavailableView(L("models.empty.title"),
                                               systemImage: "cube.box",
                                               description: Text(L("models.empty.description")))
                            .frame(height: 200)
                    } else {
                        ForEach(primaryModels, id: \.id) { model in
                            row(model)
                        }
                        if !extraModels.isEmpty {
                            DisclosureGroup(isExpanded: $showAllWhisper) {
                                VStack(alignment: .leading, spacing: Theme.Space.s) {
                                    ForEach(extraModels, id: \.id) { model in
                                        row(model)
                                    }
                                }
                                .padding(.top, Theme.Space.s)
                            } label: {
                                Text(L("models.allWhisper", extraModels.count))
                                    .font(.callout)
                                    .foregroundStyle(Theme.Color.textSecondary)
                            }
                            .padding(.top, Theme.Space.s)
                        }
                    }
                }
                .padding(Theme.Space.l)
            }
        }
        .background(Theme.Color.bgBase)
        // Обновляем при открытии раздела: отдельная кнопка «↻» была лишней.
        .onAppear { engine.refreshModels() }
    }

    /// Появляется, когда выбрана модель, отличная от активной.
    @ViewBuilder private var applyBanner: some View {
        if engine.hasPendingModel, let p = engine.pendingModel {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Theme.Color.semProcessing)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("models.pending.selected",
                           ModelCatalog.displayName(id: p.modelId)))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text(L("models.pending.hint"))
                        .font(.caption).foregroundStyle(Theme.Color.textTertiary)
                }
                Spacer(minLength: 0)
                Button(engine.isApplyingModel ? L("models.applying") : L("models.apply")) {
                    engine.applyModelRestart()
                }
                .buttonStyle(.borderedProminent).tint(Theme.Color.accent)
                .disabled(engine.isApplyingModel)
            }
            .padding(Theme.Space.s)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(Theme.Color.semProcessing.opacity(0.12)))
        }
    }

    private func row(_ model: ModelStatus) -> some View {
        ModelRow(model: progress(model),
                 isActive: model.id == engine.selection.modelId,
                 isPending: engine.hasPendingModel && model.id == engine.pendingModel?.modelId,
                 engine: engine,
                 onSelect: { engine.stageModel(selection(for: model)) })
    }

    private var primaryModels: [ModelStatus] {
        ModelCatalog.primary(engine.models,
                             activeId: engine.selection.modelId,
                             pendingId: engine.pendingModel?.modelId)
    }
    private var extraModels: [ModelStatus] {
        ModelCatalog.extraWhisper(engine.models,
                                  activeId: engine.selection.modelId,
                                  pendingId: engine.pendingModel?.modelId)
    }

    /// Семейство берём из самой записи реестра — отдельный переключатель
    /// «Parakeet / Whisper» пользователю не нужен.
    private func selection(for model: ModelStatus) -> ModelSelection {
        let family: EngineFamily = model.family.lowercased().contains("parakeet")
            ? .parakeet : .whisper
        return ModelSelection(family: family, modelId: model.id)
    }

    /// Свежий снимок прогресса перекрывает запись реестра: `listModels()`
    /// перечитывается редко, а события загрузки идут постоянно.
    private func progress(_ m: ModelStatus) -> ModelStatus {
        engine.modelProgress[m.id] ?? m
    }
}

/// Строка модели: имя, размер, языки, бейдж «Активная» и иконочные действия.
private struct ModelRow: View {
    let model: ModelStatus
    let isActive: Bool
    let isPending: Bool
    @ObservedObject var engine: Engine
    let onSelect: () -> Void

    var body: some View {
        Card(padding: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.label).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.Color.textPrimary)
                        if isActive {
                            badge(L("models.badge.active"), Theme.Color.accent)
                        } else if isPending {
                            badge(L("models.badge.selected"), Theme.Color.semProcessing)
                        }
                    }
                    Text("\(sizeText) · \(ModelCatalog.languages(family: model.family))")
                        .font(.metricSmall).foregroundStyle(Theme.Color.textTertiary)
                    if model.downloading {
                        ProgressView(value: Double(model.progressPct), total: 100)
                            .tint(Theme.Color.accent).frame(width: 220)
                            .accessibilityLabel(L("models.progress.a11y",
                                                  Int(model.progressPct)))
                    }
                    if !model.lastError.isEmpty {
                        Text(model.lastError).font(.caption2).foregroundStyle(Theme.Color.semWarning)
                    }
                }
                Spacer()
                control
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(color))
            .foregroundStyle(.white)
    }

    /// Размер модели. Ядро отдаёт точный размер для всех моделей реестра;
    /// пока он не пришёл — честное «размер уточняется», а не оценка.
    private var sizeText: String {
        if model.totalBytes > 0 { return Fmt.bytes(model.totalBytes) }
        if model.downloadedBytes > 0 { return Fmt.bytes(model.downloadedBytes) }
        return L("models.size.unknown")
    }

    @ViewBuilder private var control: some View {
        if model.downloading {
            Text("\(Int(model.progressPct))%")
                .font(.metric).foregroundStyle(Theme.Color.semProcessing)
        } else if model.installed {
            HStack(spacing: 8) {
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Color.semSuccess)
                        .accessibilityLabel(L("models.active.a11y"))
                } else {
                    Button(action: onSelect) {
                        Image(systemName: isPending ? "clock.badge.checkmark" : "checkmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .tint(Theme.Color.accent)
                    .accessibilityLabel(isPending
                                        ? L("models.select.pending")
                                        : L("models.select.a11y", model.label))
                    .help(isPending ? L("models.select.pending") : L("models.select.help"))
                }
                Button(role: .destructive) { engine.delete(modelId: model.id) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.Color.semWarning)
                .accessibilityLabel(L("models.delete.a11y", model.label))
                .help(L("models.delete.help"))
                .disabled(isActive)
            }
        } else {
            Button { engine.download(modelId: model.id) } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .tint(Theme.Color.accent)
            .accessibilityLabel(L("models.download.a11y", model.label))
            .help(L("models.download.help"))
        }
    }
}
