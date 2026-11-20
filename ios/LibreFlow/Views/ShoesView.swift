import SwiftUI

/// Settings › Shoes: distance per pair. The data lives in the analysis page; this is the native editor for it.
struct ShoesSection: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: AppModel.Shoe?

    var body: some View {
        Section {
            ForEach(model.shoes.filter { !$0.retired }) { row($0) }
            Button { editing = AppModel.Shoe() } label: { Label("Add shoes", systemImage: "plus") }
            let retired = model.shoes.filter(\.retired)
            if !retired.isEmpty {
                DisclosureGroup("Retired shoes (\(retired.count))") { ForEach(retired) { row($0) } }
            }
        } header: { Text("Shoes") } footer: {
            Text("Runs count for the default shoes of their sport from the date the shoes are in use. Change the shoes of a single run under Latest Run.")
        }
        .task { await model.refreshShoes() }
        .sheet(item: $editing) { s in ShoeEditView(shoe: s) }
    }

    private func row(_ s: AppModel.Shoe) -> some View {
        Button { editing = s } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(s.display).foregroundStyle(.primary)
                    Spacer()
                    Text("\(Int(s.km.rounded())) km").bold().foregroundStyle(.primary)
                }
                Text([s.name.isEmpty ? nil : "\(s.brand) \(s.model)", "\(s.runs) runs", s.last.map { "last \($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary)
                if s.alertKm > 0 && !s.retired {
                    ProgressView(value: min(s.km, s.alertKm), total: s.alertKm)
                        .tint(s.km >= s.alertKm ? .red : s.km >= 0.85 * s.alertKm ? .orange : .green)
                    Text(s.km >= s.alertKm ? "Past the \(Int(s.alertKm)) km reminder" : "\(Int((s.alertKm - s.km).rounded())) km to the \(Int(s.alertKm)) km reminder")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ShoeEditView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var shoe: AppModel.Shoe
    @State private var since = Date()
    @State private var alert = ""
    @State private var start = ""
    @State private var confirmDelete = false

    private static let ymd: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Brand", text: $shoe.brand)
                    TextField("Model", text: $shoe.model)
                    TextField("Nickname (optional)", text: $shoe.name)
                    DatePicker("In use since", selection: $since, displayedComponents: .date)
                }
                Section {
                    LabeledContent("Remind me at (km)") {
                        TextField("0 = off", text: $alert).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Distance before tracking (km)") {
                        TextField("0", text: $start).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                } footer: { Text("You get a reminder in the advice once the shoes pass this distance.") }
                Section("Default shoes for") {
                    ForEach(model.shoeSports, id: \.self) { sp in
                        Toggle(sp.replacingOccurrences(of: "_", with: " ").capitalized, isOn: Binding(
                            get: { shoe.sports.contains(sp) },
                            set: { on in if on { shoe.sports.append(sp) } else { shoe.sports.removeAll { $0 == sp } } }))
                    }
                }
                Section {
                    Toggle("Retired", isOn: $shoe.retired)
                } footer: { Text("Retired shoes no longer count new runs; their total is kept.") }
                if !shoe.id.isEmpty {
                    Section { Button("Delete shoes", role: .destructive) { confirmDelete = true } }
                }
            }
            .navigationTitle(shoe.id.isEmpty ? "Add shoes" : "Edit shoes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        shoe.from = Self.ymd.string(from: since)
                        shoe.alertKm = Double(alert) ?? 0
                        shoe.startKm = Double(start) ?? 0
                        Task { await model.saveShoe(shoe); dismiss() }
                    }
                    .disabled(shoe.brand.trimmingCharacters(in: .whitespaces).isEmpty || shoe.model.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete \(shoe.display)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await model.deleteShoe(shoe.id); dismiss() } }
            } message: { Text("Runs assigned to these shoes get no shoes.") }
            .onAppear {
                since = Self.ymd.date(from: shoe.from) ?? Date()
                alert = shoe.alertKm > 0 ? String(Int(shoe.alertKm)) : (shoe.id.isEmpty ? "400" : "0")
                start = shoe.startKm > 0 ? String(Int(shoe.startKm)) : ""
            }
        }
    }
}
