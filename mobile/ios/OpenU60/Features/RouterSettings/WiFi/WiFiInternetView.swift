import SwiftUI
import SafariServices

struct WiFiInternetView: View {
    let client: AgentClient
    let authManager: AuthManager
    private let choosingUpstream: Bool
    @Environment(AppModel.self) private var app
    private var model: WiFiInternetViewModel { app.device.internet }
    @State private var hotspotModel: WiFiSettingsViewModel
    @State private var join: JoinRequest?
    @State private var showAdvanced = false
    @State private var showPortal = false

    init(client: AgentClient, authManager: AuthManager, choosingUpstream: Bool = false) {
        self.client = client; self.authManager = authManager
        self.choosingUpstream = choosingUpstream
        _hotspotModel = State(initialValue: WiFiSettingsViewModel(client: client, authManager: authManager))
    }

    var body: some View {
        Form {
            if model.status?.config.mode == .hotspot && !choosingUpstream {
                CellularInternetSections(client: client, authManager: authManager)
            } else if model.status != nil {
                upstreamSections
            } else if model.refreshError == nil {
                ProgressView("Loading internet settings…")
            }
            if let error = model.refreshError { Section { Text(error).foregroundStyle(.red) } }
            if let error = model.error, join == nil, !showAdvanced {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section {
                NavigationLink("Hotspot settings") { WiFiSettingsView(viewModel: hotspotModel) }
                if model.status?.config.mode == .repeater {
                    Button("Advanced…") { model.resetAdvanced(); model.error = nil; showAdvanced = true }
                }
            }.disabled(model.busy || model.scanning)
        }
        .navigationTitle(choosingUpstream ? "Wi-Fi Repeater" : "")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.upstreamScanBand(choosingUpstream: choosingUpstream)) {
            await model.scanUpstreamIfVisible(choosingUpstream: choosingUpstream)
        }
        .sheet(item: $join, onDismiss: { model.password = "" }) { request in
            WiFiJoinView(model: model, manual: request.manual)
        }
        .sheet(isPresented: $showAdvanced) { WiFiAdvancedView(model: model) }
        .sheet(isPresented: $showPortal) {
            if let url = model.portalURL { WiFiPortalBrowser(url: url).ignoresSafeArea() }
        }
    }

    @ViewBuilder
    private var upstreamSections: some View {
        if let status = model.status {
            Section {
                WiFiConnectionOverview(status: status, statusUnavailable: model.refreshError != nil)
                if let error = status.error { Text(error).foregroundStyle(.red) }
                if status.config.mode != .hotspot {
                    if status.phase == "failed" || (status.ipv4 == nil && !status.busy) {
                        Button("Reconnect to \(status.config.ssid)") { Task { _ = await model.reconnect() } }
                            .disabled(model.busy || model.scanning)
                    }
                    Button("Use SIM hotspot") { Task { await model.useHotspot() } }
                        .disabled(model.busy || model.scanning)
                        .accessibilityIdentifier("wifi-use-hotspot")
                }
            }
        }
        Section {
            Picker("Upstream band", selection: Binding(get: { model.band }, set: { model.band = $0 })) {
                ForEach(WiFiInternetBand.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).disabled(model.busy || model.scanning)
            Button { Task { await model.scan() } } label: {
                HStack {
                    Text(model.scanInProgress ? "Scanning…" : "Scan for networks")
                    Spacer()
                    if model.scanInProgress { ProgressView().accessibilityLabel("Scanning networks") }
                }
            }.disabled(model.busy || model.scanning).accessibilityIdentifier("wifi-scan")
            if let error = model.status?.scanError { Text(error).foregroundStyle(.red) }
            ForEach(model.networks) { network in
                Button {
                    model.select(network); join = JoinRequest(manual: false)
                } label: {
                    HStack {
                        // Arcs follow the scanned signal: -60 dBm or better fills all three.
                        Image(systemName: network.supported ? "wifi" : "wifi.exclamationmark",
                              variableValue: network.supported ? (network.signal >= -60 ? 1 : network.signal >= -70 ? 0.66 : network.signal >= -80 ? 0.33 : 0) : nil)
                        Text(network.ssid).foregroundStyle(.primary)
                        Spacer()
                        if model.status?.config.ssid == network.ssid,
                           model.status?.config.band == model.band,
                           model.status?.ipv4 != nil { Image(systemName: "checkmark") }
                        if network.security != "open" { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                    }
                }.disabled(!network.supported || model.busy || model.scanning)
            }
            Button("Other…") { model.otherNetwork(); join = JoinRequest(manual: true) }
                .disabled(model.status == nil || model.busy || model.scanning)
                .accessibilityIdentifier("wifi-other-network")
        } header: { Text("Upstream Wi-Fi") }
        footer: { Text("Choose a network to connect. Your hotspot uses the other band and keeps its name and password.") }

        if model.status?.ipv4 != nil {
            Section {
                if model.portalURL != nil {
                    Button("Open Wi-Fi login page", systemImage: "globe") { showPortal = true }
                }
                Button("Check internet again") { Task { await model.checkInternet() } }.disabled(model.busy)
            } footer: { Text("For Wi-Fi sign-in, connect this iPhone to the U60 hotspot first.") }
        }
    }

    private struct JoinRequest: Identifiable {
        let id = UUID()
        let manual: Bool
    }
}

private struct CellularInternetSections: View {
    let client: AgentClient
    let authManager: AuthManager
    @Environment(AppModel.self) private var app
    private var sim: SIMViewModel { app.device.sim }
    private var mobile: MobileNetworkViewModel { app.device.mobile }

    init(client: AgentClient, authManager: AuthManager) {
        self.client = client; self.authManager = authManager
    }

    private var connectionLabel: String {
        if mobile.isLoading { return "Loading…" }
        if mobile.messageIsError { return "Status unavailable" }
        if mobile.airplaneModeEnabled { return "Airplane Mode" }
        if mobile.config.connectStatus.isEmpty { return "Status unavailable" }
        if mobile.config.isConnected { return "Connected" }
        return mobile.config.isDataEnabled ? "Not connected" : "Mobile data off"
    }

    var body: some View {
        Section {
            HStack {
                Label("SIM Hotspot", systemImage: "simcard.fill").font(.headline)
                Spacer()
                Text(connectionLabel).font(.subheadline)
                    .foregroundStyle(!mobile.isLoading && !mobile.messageIsError && mobile.config.isConnected ? .green : .secondary)
            }
            let carrier = sim.simInfo.operatorName.isEmpty ? sim.simInfo.spn : sim.simInfo.operatorName
            LabeledContent("Carrier", value: carrier.isEmpty ? (sim.isLoading ? "Loading…" : "Unavailable") : carrier)
            if !sim.isLoading && !sim.messageIsError {
                SIMPhoneNumberRow(viewModel: sim)
            }
        }
        .accessibilityIdentifier("internet-cellular-overview")
        Section {
            NavigationLink { MobileNetworkView(viewModel: mobile) } label: {
                Label("Mobile data", systemImage: "cellularbars")
            }
            NavigationLink {
                PushedModelHost(NetworkModeViewModel(client: client, authManager: authManager)) {
                    NetworkModeView(viewModel: $0)
                }
            } label: { Label("Network mode", systemImage: "antenna.radiowaves.left.and.right") }
            NavigationLink {
                PushedModelHost(APNViewModel(client: client, authManager: authManager)) { APNView(viewModel: $0) }
            } label: { Label("APN", systemImage: "network") }
            NavigationLink { SIMView(viewModel: sim) } label: {
                Label("SIM card", systemImage: "simcard")
            }
        }
        if sim.messageIsError, let message = sim.message { Section { Text(message).foregroundStyle(.red) } }
        if mobile.messageIsError, let message = mobile.message { Section { Text(message).foregroundStyle(.red) } }
        Section {
            NavigationLink {
                WiFiInternetView(client: client, authManager: authManager, choosingUpstream: true)
            } label: { Label("Use Wi-Fi repeater", systemImage: "wifi") }
            .accessibilityIdentifier("internet-choose-repeater")
        }
        .task { await mobile.refresh() }
        .task(id: sim.identityRevision) { await sim.refresh() }
    }
}

private struct WiFiConnectionOverview: View {
    let status: WiFiInternetStatus
    let statusUnavailable: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var repeater: Bool { status.config.mode == .repeater }
    private var online: Bool { !statusUnavailable && status.label == "Online" }
    private var connecting: Bool { !statusUnavailable && status.label == "Connecting…" }
    private var statusColor: Color {
        if statusUnavailable || status.phase == "failed" { return .red }
        if online { return .green }
        if status.connectivity == "captive" || status.connectivity == "limited" { return .orange }
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Text(status.sourceLabel).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    if connecting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: online ? "checkmark.circle.fill" : "circle.fill")
                            .font(.system(size: online ? 12 : 6))
                    }
                    Text(statusUnavailable ? "Status unavailable" : status.label)
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(statusColor)
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    source
                    connectionArrow("arrow.down").padding(.leading, 8)
                    router
                    connectionArrow("arrow.down").padding(.leading, 8)
                    hotspot
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    source.frame(maxWidth: .infinity)
                    connectionArrow("arrow.right").padding(.top, 8)
                    router.frame(maxWidth: .infinity)
                    connectionArrow("arrow.right").padding(.top, 8)
                    hotspot.frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wifi-connection-overview")
    }

    private var source: some View {
        step(repeater ? status.config.ssid : "SIM",
             detail: repeater ? status.config.band.label : "Mobile network",
             symbol: repeater ? "wifi" : "simcard.fill")
    }

    private var router: some View {
        step("U60 Pro", detail: repeater ? "Repeater" : "Router", symbol: "wifi.router")
    }

    private var hotspot: some View {
        step("Hotspot", detail: repeater ? status.config.band.hotspotLabel : "Wi-Fi",
             symbol: "personalhotspot")
    }

    private func connectionArrow(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private func step(_ title: String, detail: String, symbol: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(HStackLayout(spacing: 12)) :
            AnyLayout(VStackLayout(spacing: 8))
        return layout {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 32, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .center)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct WiFiJoinView: View {
    @Bindable var model: WiFiInternetViewModel
    let manual: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if manual {
                    Section {
                        TextField("Network name", text: $model.ssid)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("wifi-upstream-ssid")
                        Picker("Security", selection: $model.security) {
                            ForEach(WiFiInternetSecurity.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }
                if model.security != .open {
                    Section {
                        SecureField(model.hasSavedPassword ? "Saved password · leave blank to keep" : "Password", text: $model.password)
                            .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } footer: {
                        if model.security == .auto && !model.hasSavedPassword { Text("Leave the password blank only for an open network.") }
                    }
                }
                Section { Text("Connect to \(model.ssid.isEmpty ? "this network" : model.ssid) and share it through your \(model.band.hotspotLabel) hotspot?") }
                if let error = model.error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle(manual ? "Other Network" : model.ssid)
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissal()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.submitting) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        KeyboardDismissal.dismiss()
                        Task { if await model.connect() { dismiss() } }
                    }.disabled(model.busy || model.ssid.isEmpty).accessibilityIdentifier("wifi-connect")
                }
            }
            .interactiveDismissDisabled(model.submitting)
        }
    }
}

private struct WiFiAdvancedView: View {
    @Bindable var model: WiFiInternetViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let address = model.status?.ipv4 { Section { LabeledContent("Upstream address", value: address) } }
                Section {
                    Picker("Upstream MAC address", selection: $model.macMode) {
                        Text("Device default").tag("factory")
                        Text("Random").tag("random")
                        Text("Clone a device").tag("clone")
                    }
                    if model.macMode == "clone" {
                        TextField("MAC address", text: $model.cloneMAC)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Menu("Choose a connected device") {
                            ForEach(model.devices) { device in
                                Button("\(device.name.isEmpty ? device.ipAddress : device.name) · \(device.macAddress)") { model.cloneMAC = device.macAddress }
                            }
                            Button("Refresh devices") { Task { await model.loadDevices() } }
                        }.task { await model.loadDevices() }
                    }
                    Toggle("Use a fixed IPv4 TTL", isOn: $model.fixedTTL)
                    if model.fixedTTL { TextField("TTL (1–255)", text: $model.ttl).keyboardType(.numberPad) }
                } header: { Text("Device camouflage") }
                footer: { Text("NAT shares one upstream connection. To clone a device's Wi-Fi identity, use its MAC on that upstream network and disconnect that device there first.") }
                if let error = model.error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Advanced")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissal()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.resetAdvanced(); dismiss() }.disabled(model.submitting) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reconnect") {
                        KeyboardDismissal.dismiss()
                        Task { if await model.saveAdvanced() { dismiss() } }
                    }.disabled(model.busy)
                }
            }
            .interactiveDismissDisabled(model.submitting)
        }
    }
}

private struct WiFiPortalBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
