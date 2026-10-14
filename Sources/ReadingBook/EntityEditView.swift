import SwiftUI
import ReadingCore

/// UI-owned draft: invalid coordinate text stays intact until an explicit save.
struct EntityEditDraft: Equatable {
    let original: KnowledgeEntity
    var entity: KnowledgeEntity
    var latitude: String
    var longitude: String

    init(entity: KnowledgeEntity) {
        original = entity; self.entity = entity
        latitude = entity.latitude.map { String($0) } ?? ""
        longitude = entity.longitude.map { String($0) } ?? ""
    }

    var isDirty: Bool {
        entity != original || latitude != (original.latitude.map { String($0) } ?? "")
            || longitude != (original.longitude.map { String($0) } ?? "")
    }

    func validated(types: [EntityType]) throws -> KnowledgeEntity {
        var result = entity
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty else { throw ReadingError.invalid("名称不能为空。") }
        guard let type = types.first(where: { $0.id == result.typeID }) else {
            throw ReadingError.invalid("内容类型已变化，请重新选择。")
        }
        for field in type.fields where field.required {
            guard result.properties[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw ReadingError.invalid("请填写必填字段“\(field.label)”。")
            }
        }
        let lat = latitude.trimmingCharacters(in: .whitespacesAndNewlines)
        let lon = longitude.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lat.isEmpty == lon.isEmpty else { throw ReadingError.invalid("经度和纬度需要同时填写，或同时留空。") }
        if lat.isEmpty { result.latitude = nil; result.longitude = nil }
        else {
            guard let parsedLat = Double(lat), parsedLat.isFinite, (-90...90).contains(parsedLat) else {
                throw ReadingError.invalid("纬度应为 -90 到 90 之间的数字。")
            }
            guard let parsedLon = Double(lon), parsedLon.isFinite, (-180...180).contains(parsedLon) else {
                throw ReadingError.invalid("经度应为 -180 到 180 之间的数字。")
            }
            result.latitude = parsedLat; result.longitude = parsedLon
        }
        return result
    }
}

/// The inspector owns scrolling, save/cancel and errors; this is only its inline form.
struct EntityEditView: View {
    @Binding var draft: EntityEditDraft
    let types: [EntityType]
    @State private var showsOptionalFields = false

    private var selectedType: EntityType? { types.first { $0.id == draft.entity.typeID } }
    private var propertyKeys: [String] {
        let declared = selectedType?.fields.map(\.key) ?? []
        return declared + draft.entity.properties.keys.filter { !declared.contains($0) }.sorted()
    }
    private var primaryKeys: [String] {
        propertyKeys.filter { key in
            selectedType?.fields.first(where: { $0.key == key })?.required == true
                || draft.original.properties[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }
    private var optionalKeys: [String] { propertyKeys.filter { !primaryKeys.contains($0) } }
    private var hasSummary: Bool { !draft.original.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasGeography: Bool {
        draft.entity.typeID == "place" || draft.entity.typeID == "location" || selectedType?.name == "地点"
            || draft.original.latitude != nil || draft.original.longitude != nil
            || draft.original.locationNote?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    private var optionalCount: Int { optionalKeys.count + (hasSummary ? 0 : 1) + (hasGeography ? 0 : 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("名称 · 必填") { TextField("卡片名称", text: $draft.entity.name, axis: .vertical).lineLimit(1...3) }
            field("内容类型") {
                Picker("内容类型", selection: $draft.entity.typeID) {
                    ForEach(types) { type in Text(type.name).tag(type.id) }
                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            if hasSummary { summaryField }
            ForEach(primaryKeys, id: \.self) { propertyField($0) }
            if hasGeography { geographyFields }
            if optionalCount > 0 {
                DisclosureGroup(isExpanded: $showsOptionalFields) {
                    VStack(alignment: .leading, spacing: 12) {
                        if !hasSummary { summaryField }
                        ForEach(optionalKeys, id: \.self) { propertyField($0) }
                        if !hasGeography { geographyFields }
                    }.padding(.top, 9)
                } label: {
                    Text("更多可选字段 · \(optionalCount)").font(.caption).foregroundStyle(.secondary)
                }.tint(Palette.accent)
            }
            Text("原文依据保留；未知坐标请留空。").font(.caption).foregroundStyle(.secondary)
        }.textFieldStyle(.roundedBorder).controlSize(.small)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
    private var summaryField: some View {
        field("概述 · Markdown") {
            TextEditor(text: $draft.entity.summary).font(.body).frame(minHeight: 80, maxHeight: 130)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
        }
    }
    private func propertyField(_ key: String) -> some View {
        let definition = selectedType?.fields.first { $0.key == key }
        return field((definition?.label ?? key) + (definition?.required == true ? " · 必填" : "")) {
            TextField(definition?.label ?? key, text: Binding(get: { draft.entity.properties[key] ?? "" }, set: { draft.entity.properties[key] = $0 }), axis: .vertical)
                .lineLimit(1...6)
        }
    }
    private var geographyFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("地理坐标 · 可空") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        TextField("纬度", text: $draft.latitude).frame(minWidth: 88)
                        TextField("经度", text: $draft.longitude).frame(minWidth: 88)
                    }
                    VStack(spacing: 7) { TextField("纬度", text: $draft.latitude); TextField("经度", text: $draft.longitude) }
                }
            }
            field("位置依据 / 待考说明") {
                TextField("位置依据", text: Binding(get: { draft.entity.locationNote ?? "" }, set: { draft.entity.locationNote = $0 }), axis: .vertical).lineLimit(1...4)
            }
        }
    }
}
