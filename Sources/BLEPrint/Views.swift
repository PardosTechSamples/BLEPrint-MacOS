import BLEPrintCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        VStack(spacing: 10) {
            topBar
            HSplitView {
                settingsPane.frame(minWidth: 430, idealWidth: 520)
                outputPane.frame(minWidth: 380, idealWidth: 440)
            }
        }
        .padding(12)
        .frame(minWidth: 900, minHeight: 680)
        .sheet(isPresented: $m.showScan) { ScanSheet().environmentObject(m) }
        .alert("Label \(m.pause?.done ?? 0) of \(m.pause?.total ?? 0) printed", isPresented: Binding(
            get: { m.pause != nil }, set: { if !$0 && m.pause != nil { m.answerPause(false) } })) {
            Button("Continue") { m.answerPause(true) }.keyboardShortcut(.defaultAction)
            Button("Stop printing", role: .cancel) { m.answerPause(false) }
        } message: { Text("Cut it on the printer, then press Continue for the next label.") }
        .confirmationDialog("Print all \(m.rows.count) rows × \(max(1, m.copies)) copy each?", isPresented: $m.confirmPrintAll) {
            Button("Print all") { m.printAll() }
        }
    }

    // MARK: top bar

    var topBar: some View {
        HStack(spacing: 10) {
            Text("BLEPrint").font(.system(size: 17, weight: .heavy))
            Text("for Nelko® P21 · Supvan® E10").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(m.csvName).font(.caption).foregroundStyle(.secondary)
            Button("Open CSV…") { m.openCSV() }
            Text(m.device.map { "\($0.brand?.displayName ?? "?") · \($0.name)" } ?? "\(m.brand.displayName) (not connected)")
                .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
            Button("Find printer…") { m.showScan = true; m.scan() }.disabled(m.busy)
            Label(m.connected ? "connected" : "disconnected", systemImage: "circle.fill")
                .labelStyle(.titleAndIcon).font(.caption.bold())
                .foregroundStyle(m.connected ? .green : .red)
            Button(m.connected ? "Disconnect" : "Connect") { m.toggleConnection() }
                .buttonStyle(.borderedProminent).tint(m.connected ? .gray : .green).disabled(m.busy)
        }
    }

    // MARK: settings

    var settingsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Label size (mm) & print settings") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            Text("Width across head"); num($m.headMM).disabled(m.brand.fixedHeadMM != nil)
                            Text("Length along feed"); num($m.feedMM).disabled(m.fitActive)
                        }
                        GridRow {
                            Text("Gap"); num($m.gapMM).disabled(!m.brand.usesGap)
                                .help("Set by the printer from the loaded label roll.")
                            Text("Density (\(m.brand.densityRange.lowerBound)-\(m.brand.densityRange.upperBound))")
                            Stepper(value: $m.density, in: m.brand.densityRange) { Text("\(m.density)").monospacedDigit().frame(width: 28) }
                        }
                        GridRow {
                            Text("Speed")
                            Stepper(value: $m.speed, in: 1...6) { Text("\(m.speed)").monospacedDigit().frame(width: 28) }
                                .disabled(!m.brand.usesSpeed)
                            Text("Copies / row")
                            Stepper(value: $m.copies, in: 1...99) { Text("\(m.copies)").monospacedDigit().frame(width: 28) }
                        }
                    }.padding(6)
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Fit length to text (print edge to edge)", isOn: Binding(get: { m.fitActive }, set: { m.fitLength = $0 }))
                            .disabled(!m.brand.supportsFitLength)
                            .help(m.brand.supportsFitLength ? "" : "Only on continuous-tape printers (Supvan).")
                        Picker("Print as", selection: $m.mode) {
                            ForEach(PrintMode.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).help("QR codes scan best with short text, such as a URL or SKU.")
                        Toggle("Continuous print (all labels in one job)", isOn: Binding(get: { m.continuousActive }, set: { m.continuous = $0 }))
                            .disabled(!m.brand.supportsContinuous)
                        Text(m.brand.continuousNote).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(6)
                }
                GroupBox("Template — click a column to insert {Column}") {
                    VStack(alignment: .leading, spacing: 8) {
                        if !m.columns.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack { ForEach(m.columns, id: \.self) { c in Button(c) { m.insertColumn(c) } } }
                            }
                        }
                        TextEditor(text: $m.template).font(.system(.body, design: .monospaced))
                            .frame(height: 110).scrollContentBackground(.hidden)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                        HStack {
                            Button { m.go(-1) } label: { Image(systemName: "chevron.left") }
                            Text("row \(m.rows.isEmpty ? 0 : m.current + 1) / \(m.rows.count)").monospacedDigit()
                            Button { m.go(1) } label: { Image(systemName: "chevron.right") }
                            Spacer()
                        }
                    }.padding(6)
                }
                HStack {
                    Button { m.printCurrent() } label: { Text("Print this row").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button { if m.rows.isEmpty { m.say("Open a CSV first.") } else { m.confirmPrintAll = true } } label: {
                        Text("Print ALL rows").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(.orange).controlSize(.large)
                }.disabled(m.busy || !m.connected)
            }.padding(.trailing, 6)
        }
    }

    func num(_ v: Binding<Double>) -> some View {
        TextField("", value: v, format: .number.precision(.fractionLength(0...1))).frame(width: 64)
            .textFieldStyle(.roundedBorder)
    }

    // MARK: preview + log

    var outputPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview (as printed)").font(.caption).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35))
                if let p = m.preview {
                    Image(decorative: p, scale: 1).interpolation(.none).resizable().aspectRatio(contentMode: .fit)
                        .padding(10)
                }
            }.frame(height: 200)
            Text("Log").font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(m.log.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(.green)
                                .textSelection(.enabled).id(i)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.6)))
                .onChange(of: m.log.count) { n in proxy.scrollTo(n - 1, anchor: .bottom) }
            }
            ProgressView(value: Double(m.progress.value), total: Double(m.progress.total))
        }
    }
}

struct ScanSheet: View {
    @EnvironmentObject var m: AppModel
    @State private var selection: UUID?

    var rows: [FoundDevice] { m.scanResults.filter { $0.brand != nil || m.showAllDevices } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find printer").font(.title3.bold())
            Text("Turn the printer on and close its phone app, then search. Supported printers are listed first; the brand is detected from the MAC prefix (OUI), the device name or its Bluetooth service.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Table(rows, selection: $selection) {
                TableColumn("Name") { d in Text(d.name.isEmpty ? "(no name)" : d.name).foregroundStyle(d.brand == nil ? .secondary : .primary) }
                TableColumn("Brand") { d in Text(d.brand?.displayName ?? "—") }.width(70)
                TableColumn("Detected by") { d in Text(d.reason.isEmpty ? "—" : d.reason).help(d.reason) }
                TableColumn("MAC") { d in Text(d.mac ?? "hidden").monospaced() }.width(140)
                TableColumn("Signal") { d in Text("\(d.rssi) dBm").monospacedDigit() }.width(70)
            }
            .frame(minHeight: 260)
            .onChange(of: m.scanResults.count) { _ in selection = rows.first(where: { $0.brand != nil })?.id }
            HStack {
                Toggle("Show all Bluetooth devices", isOn: $m.showAllDevices)
                Spacer()
                if m.scanning { ProgressView().controlSize(.small); Text("Searching…").font(.caption) }
                Button("Search again") { m.scan() }.disabled(m.scanning)
                Button("Cancel") { m.showScan = false }.keyboardShortcut(.cancelAction)
                Button("Connect") { if let d = rows.first(where: { $0.id == selection }) { m.connect(d) } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(rows.first(where: { $0.id == selection })?.brand == nil)
            }
        }
        .padding(16)
        .frame(width: 760, height: 420)
    }
}
