import SwiftUI
import ReadingCore

/// All spatial components ask the same canonical objects for a time snapshot.
@MainActor extension AppStore {
    var temporalBoundary: KnowledgeReadBoundary {
        guard let book, book.temporalKnowledge?.profile?.avoidsSpoilers ?? true, let selectedUnitID,
              let boundary = try? KnowledgeReadBoundary.throughSourceUnit(selectedUnitID, in: book) else { return .all }
        return boundary
    }
    var temporalPoint: TemporalQueryPoint? {
        if temporalAxis == "narrative" { return .narrative(Int(timeCursor)) }
        if temporalAxis.hasPrefix("calendar:") {
            return .date(TemporalDate(year: Int(timeCursor)), calendar: String(temporalAxis.dropFirst(9)))
        }
        return nil // Legacy year labels have no verified calendar.
    }
    var temporalCalendars: [String] {
        Array(Set(availableTemporalExtents.compactMap(\.calendar))).sorted()
    }
    var hasNarrativeTime: Bool {
        availableTemporalExtents.contains { $0.narrativeStart != nil }
    }
    var availableTemporalExtents: [TemporalExtent] {
        guard let book, let state = book.temporalKnowledge else { return [] }
        let anchors = Dictionary(((book.readingExperience?.anchors ?? []) + state.anchors).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func admits(_ ids: [String]) -> Bool {
            guard let allowed = temporalBoundary.allowedUnitIDs else { return true }
            return !ids.isEmpty && ids.allSatisfy { id in anchors[id].map { allowed.contains($0.unitID) } ?? false }
        }
        return state.presences.filter { admits($0.sourceAnchorIDs) }.map(\.extent)
            + state.participations.filter { admits($0.sourceAnchorIDs) }.compactMap(\.extent)
            + state.eventMetadata.filter { admits($0.sourceAnchorIDs) }.compactMap(\.extent)
            + state.relationMetadata.filter { admits($0.sourceAnchorIDs) }.map(\.validity)
    }
    func temporalSnapshot(_ id: String, at point: TemporalQueryPoint? = nil) -> EntityTimeSnapshot? {
        guard let book else { return nil }
        return try? TemporalKnowledgeRuntime.entitySnapshot(entityID: id, in: book, at: point ?? temporalPoint, boundary: temporalBoundary)
    }
    var temporalEvents: [TemporalEventSnapshot] {
        guard let book else { return [] }
        return (try? TemporalKnowledgeRuntime.events(in: book, entityID: selectedTemporalEntityID,
            at: selectedTemporalEntityID == nil ? nil : temporalPoint, boundary: temporalBoundary)) ?? []
    }
    var temporalValueLabel: String {
        temporalAxis == "narrative" ? "叙事位置 \(Int(timeCursor))" : TimelineRangeControl.yearLabel(Int(timeCursor))
    }
}

struct TemporalPersonContents: View {
    @EnvironmentObject var store: AppStore
    let entityID: String
    var body: some View {
        let snapshot = store.temporalSnapshot(entityID)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(store.temporalValueLabel, systemImage: "clock").font(.subheadline).foregroundStyle(Palette.accent)
                if let object = snapshot?.object {
                    Text(object.name).font(.system(size: 20, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if !object.summary.isEmpty { MarkdownText(markdown: object.summary) }
                }
                if store.temporalPoint == nil {
                    Text("当前使用原书纪年标签，尚未统一历法。请在时间轴选择明确历法或叙事顺序后，查看此时的行动。")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                } else if let snapshot {
                    if snapshot.presences.isEmpty && snapshot.participations.isEmpty {
                        Text("此时没有已记录的行动或位置。不会沿用其他时期的位置。")
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.presences) { presence in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(presence.action).font(.system(size: 15, weight: .medium))
                            if let place = presence.placeID { Label(store.objectTitle(place), systemImage: "mappin.and.ellipse").font(.caption) }
                            anchorEvidence(presence.sourceAnchorIDs)
                        }.padding(12).background(Palette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                    }
                    ForEach(snapshot.events.filter { $0.match == .matches }, id: \.object.id) { event in
                        Button { store.focus(event.object.id) } label: {
                            Label(event.object.name, systemImage: "flag").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if !snapshot.relations.isEmpty {
                        Text("此时关系").font(.subheadline.weight(.semibold))
                        ForEach(snapshot.relations.filter { $0.match == .matches }, id: \.relation.id) { item in
                            Text("\(store.objectTitle(item.relation.fromID)) · \(item.relation.label) · \(store.objectTitle(item.relation.toID))").font(.system(size: 15))
                        }
                    }
                    if !snapshot.uncertainPresences.isEmpty || !snapshot.uncertainParticipations.isEmpty {
                        DisclosureGroup("时间或位置尚待核对") {
                            ForEach(snapshot.uncertainPresences) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.action).font(.system(size: 15))
                                    Text(item.extent.sourceText.isEmpty ? "时间未明" : item.extent.sourceText).font(.caption).foregroundStyle(.secondary)
                                    anchorEvidence(item.sourceAnchorIDs)
                                }.padding(.vertical, 6)
                            }
                            ForEach(snapshot.uncertainParticipations) { item in
                                Text("\(store.objectTitle(item.eventID)) · \(item.role)").font(.system(size: 15))
                            }
                        }.font(.caption)
                    }
                }
                Text("地图仅标出有独立出处的出现记录；参与某事件不自动等于到过它的所有地点。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private func anchorEvidence(_ ids: [String]) -> some View {
        let anchors = store.book?.temporalKnowledge?.anchors.filter { ids.contains($0.id) } ?? []
        if !anchors.isEmpty { EvidenceDisclosure(evidence: anchors.map { Evidence(unitID: $0.unitID, quote: $0.quote) }) }
    }
}
