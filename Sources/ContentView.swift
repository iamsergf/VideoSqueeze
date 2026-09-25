import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.items.isEmpty {
                    dropZone
                } else {
                    list
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.add(urls)
                return true
            } isTargeted: { isTargeted = $0 }

            Divider()
            controls
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    private var dropZone: some View {
        Button(action: model.openPanel) {
            VStack(spacing: 14) {
                Image(systemName: "film.stack")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                Text("Перетащите видео сюда")
                    .font(.title2.weight(.medium))
                Text("или нажмите, чтобы выбрать файлы")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
            )
            .contentShape(Rectangle())
            .padding(24)
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        List {
            ForEach(model.items) { item in
                ItemRow(item: item)
                    .contextMenu {
                        if item.outputURL != nil {
                            Button("Показать в Finder") { model.reveal(item) }
                        }
                        Button("Убрать из списка") { model.remove(item) }
                            .disabled(item.status == .running)
                    }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(4)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Picker("Режим", selection: $model.settings.mode) {
                    ForEach(CompressionMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if model.settings.mode == .quality {
                    Picker("Качество", selection: $model.settings.quality) {
                        ForEach(Quality.allCases) { Text($0.rawValue).tag($0) }
                    }
                } else {
                    HStack(spacing: 6) {
                        Text("Не больше")
                        TextField("МБ", value: $model.settings.targetSizeMB,
                                  format: .number.precision(.fractionLength(0...1)))
                            .frame(width: 56)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: $model.settings.targetSizeMB, in: 1...4000, step: 1)
                            .labelsHidden()
                        Text("МБ")
                    }
                }
            }
            .disabled(model.isRunning)
            .fixedSize()

            HStack(spacing: 16) {
                Picker("Кодек", selection: $model.settings.codec) {
                    ForEach(Codec.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Макс. разрешение", selection: $model.settings.resolution) {
                    ForEach(MaxResolution.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Звук", isOn: $model.settings.keepAudio)
            }
            .disabled(model.isRunning)
            .fixedSize()

            if model.settings.mode == .targetSize {
                Text("Разрешение подбирается автоматически: чем длиннее видео, тем ниже. "
                     + "Для 5 МБ комфортно ~1–2 минуты, дальше качество заметно падает.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Добавить…", action: model.openPanel)
                Button("Очистить", action: model.clear)
                    .disabled(model.items.isEmpty || model.isRunning)
                Spacer()
                Text("Файлы сохраняются рядом с оригиналом (_compressed.mp4)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.isRunning {
                    Button("Остановить", role: .cancel, action: model.stop)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Сжать", action: model.start)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.hasPending)
                }
            }
        }
        .padding(16)
    }
}

struct ItemRow: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.body.weight(.medium))
                if item.status == .running {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if item.outputURL != nil {
                Button {
                    model.reveal(item)
                } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.borderless)
                .help("Показать в Finder")
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch item.status {
        case .pending: return "film"
        case .running: return "gearshape.2"
        case .done: return "checkmark.circle.fill"
        case .cancelled: return "stop.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch item.status {
        case .done: return .green
        case .failed: return .orange
        case .running: return .accentColor
        default: return .secondary
        }
    }

    private var detail: String {
        let original = format(item.originalSize)
        switch item.status {
        case .pending: return original
        case .running: return "\(original) · \(Int(item.progress * 100))%"
        case .cancelled: return "\(original) · отменено"
        case .failed(let msg): return "Ошибка: \(msg)"
        case .done:
            guard let out = item.outputSize, item.originalSize > 0 else { return original }
            let change = Double(out - item.originalSize) / Double(item.originalSize) * 100
            let sign = change > 0 ? "+" : "−"
            var text = "\(original) → \(format(out))  (\(sign)\(Int(abs(change).rounded()))%)"
            if let r = item.result {
                text += " · \(Int(min(r.size.width, r.size.height)))p"
                if r.fps < 23 { text += ", \(Int(r.fps.rounded())) к/с" }
            }
            if let target = item.targetBytes, out > target {
                text += " — не удалось уложиться в \(format(target))"
            } else if change > 0 {
                text += " — файл уже был хорошо сжат"
            }
            return text
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
