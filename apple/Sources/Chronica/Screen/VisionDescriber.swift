import Foundation

/// Бэкенд «опиши скриншот». Абстракция, чтобы рантайм был заменяемым
/// (Ollama сегодня; MLX/llama.cpp встраиваемые — возможные завтра) и
/// тестируемым (mock в юнит-тестах ScreenObserver).
protocol VisionDescriber: Sendable {
    /// Описание работы на скриншоте (jpeg, base64). Бросает при недоступности.
    func describe(jpegBase64: String, app: String, windowTitle: String) async throws -> String
    /// Быстрая проверка доступности бэкенда (для статуса в Настройках).
    func probe() async -> VisionProbe
}

/// Результат проверки бэкенда.
enum VisionProbe: Equatable {
    case ready
    /// Сервис доступен, но модель не установлена (подсказка с командой).
    case modelMissing(hint: String)
    /// Сервис недоступен (не запущен/не установлен).
    case unavailable(hint: String)
}

/// Локальная vision-LLM через Ollama (`http://127.0.0.1:11434`).
///
/// Почему Ollama: единственный способ получить НАСТОЯЩУЮ маленькую vision-LLM
/// (по умолчанию `qwen3-vl:2b` под Apache-2.0; годятся и moondream и другие)
/// локально без встраивания тяжёлого ML-рантайма в приложение. Всё on-device:
/// скриншот не покидает машину.
struct OllamaDescriber: VisionDescriber {
    /// Замыкание транспорта — production использует URLSession, тесты могут
    /// подставить cancellation-aware double без запуска Ollama.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    var baseURL: URL
    var model: String
    /// Таймаут одной генерации; маленькие VLM на Apple Silicon отвечают за
    /// секунды, но первая загрузка модели в память может быть долгой. Сверху
    /// ограничен 120 сек; отмена тика всё равно немедленно прекращает
    /// cancellation-aware транспорт.
    var timeout: TimeInterval = 120
    private var transport: Transport

    init(baseURL: URL,
         model: String,
         timeout: TimeInterval = 120,
         transport: @escaping Transport = { request in
             try await URLSession.shared.data(for: request)
         }) {
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
        self.transport = transport
    }

    func describe(jpegBase64: String, app: String, windowTitle: String) async throws -> String {
        try Task.checkCancellation()
        struct GenerateRequest: Encodable {
            let model: String
            let prompt: String
            let images: [String]
            let stream: Bool
            let options: [String: Double]
        }
        struct GenerateResponse: Decodable { let response: String }

        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.timeoutInterval = Self.boundedTimeout(timeout)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(GenerateRequest(
            model: model,
            prompt: VisionPrompt.build(app: app, windowTitle: windowTitle),
            images: [jpegBase64],
            stream: false,
            // Низкая температура: нужен фактический лог, не сочинение.
            options: ["temperature": 0.2, "num_predict": 160]
        ))
        let (data, resp) = try await requestData(req)
        try Task.checkCancellation()
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw VisionError.backend("Ollama HTTP \(code): \(body)")
        }
        let text = try JSONDecoder().decode(GenerateResponse.self, from: data).response
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func probe() async -> VisionProbe {
        if Task.isCancelled { return .unavailable(hint: L("vision.probe.cancelled")) }
        struct TagsResponse: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = min(Self.boundedTimeout(timeout), 3)
        do {
            let (data, resp) = try await requestData(req)
            try Task.checkCancellation()
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return .unavailable(hint: L("vision.probe.httpError"))
            }
            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            // Совпадение по префиксу: "qwen3-vl:2b" числится как есть, а
            // "moondream" может быть "moondream:latest".
            let base = model.split(separator: ":").first.map(String.init) ?? model
            if tags.models.contains(where: { $0.name == model || $0.name.hasPrefix(base + ":") }) {
                return .ready
            }
            return .modelMissing(hint: "ollama pull \(model)")
        } catch {
            return .unavailable(hint: L("vision.probe.installHint", model))
        }
    }

    private static func boundedTimeout(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 120 }
        return min(max(value, 1), 120)
    }

    /// URLRequest.timeoutInterval обычно достаточно для URLSession, но держим
    /// явную гонку с cancellation-aware sleep и для injected transport'ов. Это
    /// гарантирует, что зависший локальный backend не удерживает тик бесконечно.
    private func requestData(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let transport = self.transport
        let seconds = Self.boundedTimeout(request.timeoutInterval)
        let nanos = UInt64(seconds * 1_000_000_000)
        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await transport(request) }
            group.addTask {
                try await Task.sleep(nanoseconds: nanos)
                throw VisionError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw VisionError.timeout }
            return first
        }
    }
}

/// Ошибки vision-бэкенда.
///
/// Конформанс `LocalizedError` обязателен: `Engine.humanMessage` печатает
/// именно `errorDescription`, иначе в интерфейс попадал бы сырой дамп кейса
/// (`backend("Ollama HTTP 404: …")`).
enum VisionError: Error, LocalizedError, CustomStringConvertible {
    case backend(String)
    case timeout
    var description: String {
        switch self {
        case .backend(let m): return m
        case .timeout: return L("vision.error.timeout")
        }
    }
    var errorDescription: String? { description }
}
