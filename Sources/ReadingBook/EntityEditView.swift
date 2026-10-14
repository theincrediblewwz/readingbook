import SwiftUI
import ReadingCore

struct EntityEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var entity: KnowledgeEntity
    @State private var latitude = ""
    @State private var longitude = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑卡片").font(.system(size: 18, weight: .semibold))
            Form {
                TextField("名称", text: $entity.name)
                Picker("内容类型", selection: $entity.typeID) { ForEach(store.book?.types ?? []) { type in Text(type.name).tag(type.id) } }
                Text("概述").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $entity.summary).frame(height: 100).font(.body).overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.15)))
                ForEach(propertyKeys, id: \.self) { key in
                    TextField(store.book?.types.first { $0.id == entity.typeID }?.fields.first { $0.key == key }?.label ?? key, text: Binding(get: { entity.properties[key] ?? "" }, set: { entity.properties[key] = $0 }))
                }
                HStack { TextField("纬度（可空）", text: $latitude); TextField("经度（可空）", text: $longitude) }
                TextField("位置依据 / 待考说明", text: Binding(get: { entity.locationNote ?? "" }, set: { entity.locationNote = $0 }))
            }.formStyle(.grouped).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("原文依据保留；用户编辑会记录到操作历史。未知坐标请留空。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("取消") { dismiss() }; Spacer(); Button("保存") { save() }.buttonStyle(.borderedProminent).disabled(store.isBusy) }
        }.padding(18).frame(width: 540, height: 540).controlSize(.small)
            .onAppear { latitude = entity.latitude.map { String($0) } ?? ""; longitude = entity.longitude.map { String($0) } ?? "" }
    }
    private var propertyKeys: [String] { Array(Set(entity.properties.keys).union(store.book?.types.first { $0.id == entity.typeID }?.fields.map(\.key) ?? [])).sorted() }
    private func save() {
        let lat = latitude.trimmingCharacters(in: .whitespacesAndNewlines), lon = longitude.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lat.isEmpty || Double(lat) != nil, lon.isEmpty || Double(lon) != nil else { store.errorMessage = "坐标应为数字，或保持空白。"; return }
        entity.latitude = lat.isEmpty ? nil : Double(lat); entity.longitude = lon.isEmpty ? nil : Double(lon)
        Task { await store.saveEntity(entity); if store.errorMessage == nil { dismiss() } }
    }
}
