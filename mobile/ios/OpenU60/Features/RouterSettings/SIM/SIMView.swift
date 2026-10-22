import SwiftUI

struct SIMView: View {
    @Bindable var viewModel: SIMViewModel

    var body: some View {
        List {

            if viewModel.isPinLocked {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SIM PIN Required")
                                .font(.headline)
                            Text("Enter your PIN to unlock the SIM card")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.orange)
                    }

                    Button {
                        viewModel.pinSheetAction = .verify
                        viewModel.pinInput = ""
                        viewModel.sheetError = nil
                        viewModel.showEnterPinSheet = true
                    } label: {
                        Text("Enter PIN")
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            if viewModel.isPukLocked {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SIM PUK Required")
                                .font(.headline)
                            Text("Too many wrong PIN attempts. Enter PUK to unlock.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.lock.fill")
                            .foregroundStyle(.red)
                    }

                    Button {
                        viewModel.pukInput = ""
                        viewModel.newPinInput = ""
                        viewModel.sheetError = nil
                        viewModel.showEnterPukSheet = true
                    } label: {
                        Text("Enter PUK")
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            Section("SIM Card") {
                statusRow
                infoRow("ICCID", viewModel.simInfo.iccid)
                infoRow("IMSI", viewModel.simInfo.imsi)
                SIMPhoneNumberRow(viewModel: viewModel)
                infoRow("SPN", viewModel.simInfo.spn)
                mccMncRow
                if !viewModel.simInfo.operatorName.isEmpty {
                    infoRow("Operator", viewModel.simInfo.operatorName)
                }
                infoRow("SIM Slot", viewModel.simInfo.currentSlot)
            }

            Section("PIN Management") {
                pinStatusRow

                HStack {
                    Text("PIN Attempts")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(viewModel.simInfo.pinAttempts)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(viewModel.simInfo.pinAttempts > 0 && viewModel.simInfo.pinAttempts <= 1 ? .red : .primary)
                }

                HStack {
                    Text("PUK Attempts")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(viewModel.simInfo.pukAttempts)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(viewModel.simInfo.pukAttempts > 0 && viewModel.simInfo.pukAttempts <= 3 ? .orange : .primary)
                }

                if !viewModel.isPinLocked && !viewModel.isPukLocked {
                    if viewModel.isPinEnabled {
                        Button {
                            viewModel.pinSheetAction = .disableLock
                            viewModel.pinInput = ""
                            viewModel.sheetError = nil
                            viewModel.showEnterPinSheet = true
                        } label: {
                            Label("Disable PIN Lock", systemImage: "lock.open")
                        }
                    } else {
                        Button {
                            viewModel.pinSheetAction = .enableLock
                            viewModel.pinInput = ""
                            viewModel.sheetError = nil
                            viewModel.showEnterPinSheet = true
                        } label: {
                            Label("Enable PIN Lock", systemImage: "lock")
                        }
                    }

                    Button {
                        viewModel.oldPinInput = ""
                        viewModel.newPinInput = ""
                        viewModel.sheetError = nil
                        viewModel.showChangePinSheet = true
                    } label: {
                        Label("Change PIN", systemImage: "pencil")
                    }
                }
            }

            Section("SIM Lock") {
                HStack {
                    Text("Unlock Attempts")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(viewModel.lockInfo.availableTrials)")
                        .font(.body.monospacedDigit())
                }

                if viewModel.lockInfo.availableTrials > 0 {
                    Button {
                        viewModel.nckInput = ""
                        viewModel.sheetError = nil
                        viewModel.showUnlockSheet = true
                    } label: {
                        Label("Enter Unlock Code", systemImage: "lock.open")
                    }
                }
            }
        }
        .navigationTitle("SIM Card")
        .keyboardDismissal()
        .refreshable { await viewModel.refresh() }
        .operationStatus(message: viewModel.message, isError: viewModel.messageIsError, isLoading: viewModel.isLoading)
        .task(id: viewModel.identityRevision) { await viewModel.refresh() }
        .sheet(isPresented: $viewModel.showChangePinSheet) {
            ChangePinSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showEnterPinSheet) {
            EnterPinSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showEnterPukSheet) {
            EnterPukSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showUnlockSheet) {
            UnlockSIMSheet(viewModel: viewModel)
        }
    }

    // MARK: - Rows

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "--" : value)
                .font(.body.monospacedDigit())
                .textSelection(.enabled)
        }
    }

    private var mccMncRow: some View {
        let mcc = viewModel.simInfo.mcc
        let mnc = viewModel.simInfo.mnc
        let value = (mcc.isEmpty && mnc.isEmpty) ? "" : "\(mcc)/\(mnc)"
        return infoRow("MCC/MNC", value)
    }

    private var statusRow: some View {
        let raw = viewModel.simInfo.simStatus
        let modem = viewModel.simInfo.modemMainState.lowercased()
        let effective: String
        if raw.isEmpty && !modem.isEmpty {
            effective = modem == "modem_waitpin" ? "wait pin"
                      : modem == "modem_waitpuk" ? "wait puk"
                      : modem == "modem_init_complete" ? "sim ready"
                      : raw
        } else {
            effective = raw
        }
        let label = simStatusLabel(effective)
        let color = simStatusColor(effective)
        return HStack {
            Text("Status")
                .foregroundStyle(.secondary)
            Spacer()
            Text(label)
                .font(.body.monospacedDigit())
                .foregroundStyle(color)
        }
    }

    private var pinStatusRow: some View {
        let enabled = viewModel.isPinEnabled
        return HStack {
            Text("PIN Lock")
                .foregroundStyle(.secondary)
            Spacer()
            Text(enabled ? "Enabled" : "Disabled")
                .font(.body.monospacedDigit())
                .foregroundStyle(enabled ? .green : .secondary)
        }
    }

    // MARK: - Helpers

    private func simStatusLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "", "unknown": return "--"
        case "sim ready": return "Ready"
        case "sim undetected": return "No SIM"
        case "wait pin": return "PIN Required"
        case "wait puk": return "PUK Required"
        case "sim destroy": return "SIM Destroyed"
        case "error", "sim_error": return "Error"
        default: return raw
        }
    }

    private func simStatusColor(_ raw: String) -> Color {
        switch raw.lowercased() {
        case "sim ready": return .green
        case "sim undetected": return .red
        case "wait pin", "wait puk": return .orange
        case "sim destroy": return .red
        case "error", "sim_error": return .red
        default: return .secondary
        }
    }
}

struct SIMPhoneNumberRow: View {
    let viewModel: SIMViewModel
    @State private var edit: PhoneNumberEdit?

    var body: some View {
        Button {
            edit = PhoneNumberEdit(sim: viewModel.simInfo)
        } label: {
            HStack {
                Text("Phone number").foregroundStyle(.primary)
                Spacer()
                Text(viewModel.simInfo.msisdn.isEmpty ? "Add number" : viewModel.simInfo.msisdn)
                    .foregroundStyle(viewModel.simInfo.msisdn.isEmpty ? .blue : .secondary)
                    .monospacedDigit()
                Image(systemName: "pencil").font(.footnote)
            }
        }
        .disabled(viewModel.isLoading || !viewModel.simInfo.canEditPhoneNumber)
        .accessibilityIdentifier("sim-phone-number")
        .sheet(item: $edit) { selection in
            SIMPhoneNumberEditor(viewModel: viewModel, sim: selection.sim)
        }
    }

    private struct PhoneNumberEdit: Identifiable {
        let sim: SIMInfo
        var id: String { sim.iccid }
    }
}

private struct SIMPhoneNumberEditor: View {
    let viewModel: SIMViewModel
    let sim: SIMInfo
    @Environment(\.dismiss) private var dismiss
    @State private var number: String
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    init(viewModel: SIMViewModel, sim: SIMInfo) {
        self.viewModel = viewModel; self.sim = sim
        _number = State(initialValue: sim.msisdn)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Phone number", text: $number)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .disabled(saving)
                        .accessibilityIdentifier("sim-phone-number-input")
                } footer: {
                    Text("Saved on U60 for this SIM, so all your phones share it. Leave blank to use the SIM's number.")
                }
                if sim.phoneNumberIsManual {
                    Section {
                        Button("Use SIM number") { Task { await save("") } }
                            .disabled(saving)
                            .accessibilityIdentifier("sim-phone-number-reset")
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Phone number")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissal()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save(number) } } label: {
                        if saving { ProgressView() } else { Text("Save") }
                    }
                    .disabled(saving || SIMPhoneNumber.normalized(number) == nil)
                    .accessibilityIdentifier("sim-phone-number-save")
                }
            }
            .interactiveDismissDisabled(saving)
            .task { focused = true }
        }
    }

    private func save(_ input: String) async {
        saving = true; error = nil; focused = false
        do {
            try await viewModel.savePhoneNumber(input, for: sim.iccid)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }
}

// MARK: - Sheets

/// Renders a failed attempt inside the presented sheet; `SIMView`'s own message row is behind it.
private struct SheetErrorFooter: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .foregroundStyle(.red)
        }
    }
}

struct ChangePinSheet: View {
    @Bindable var viewModel: SIMViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Current PIN") {
                    SecureField("Old PIN", text: $viewModel.oldPinInput)
                        .keyboardType(.numberPad)
                }

                Section("New PIN") {
                    SecureField("New PIN", text: $viewModel.newPinInput)
                        .keyboardType(.numberPad)
                }

                Section {
                    Button {
                        Task { await viewModel.changePin() }
                    } label: {
                        Text("Change PIN")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(viewModel.oldPinInput.count < 4 || viewModel.newPinInput.count < 4 || viewModel.isLoading)
                } footer: {
                    SheetErrorFooter(message: viewModel.sheetError)
                }
            }
            .navigationTitle("Change PIN")
            .keyboardDismissal()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct EnterPinSheet: View {
    @Bindable var viewModel: SIMViewModel
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        switch viewModel.pinSheetAction {
        case .verify: return "Enter PIN"
        case .enableLock: return "Enable PIN Lock"
        case .disableLock: return "Disable PIN Lock"
        }
    }

    private var buttonLabel: String {
        switch viewModel.pinSheetAction {
        case .verify: return "Unlock"
        case .enableLock: return "Enable"
        case .disableLock: return "Disable"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("PIN", text: $viewModel.pinInput)
                        .keyboardType(.numberPad)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if viewModel.pinSheetAction == .verify {
                            Text("\(viewModel.simInfo.pinAttempts) attempts remaining")
                        }
                        SheetErrorFooter(message: viewModel.sheetError)
                    }
                }

                Section {
                    Button {
                        Task { await viewModel.submitPin() }
                    } label: {
                        Text(buttonLabel)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(viewModel.pinInput.count < 4 || viewModel.isLoading)
                }
            }
            .navigationTitle(title)
            .keyboardDismissal()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct EnterPukSheet: View {
    @Bindable var viewModel: SIMViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("PUK Code", text: $viewModel.pukInput)
                        .keyboardType(.numberPad)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(viewModel.simInfo.pukAttempts) attempts remaining")
                        SheetErrorFooter(message: viewModel.sheetError)
                    }
                }

                Section("New PIN") {
                    SecureField("New PIN", text: $viewModel.newPinInput)
                        .keyboardType(.numberPad)
                }

                Section {
                    Button {
                        Task { await viewModel.verifyPuk() }
                    } label: {
                        Text("Unlock")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(viewModel.pukInput.count < 8 || viewModel.newPinInput.count < 4 || viewModel.isLoading)
                }
            }
            .navigationTitle("Enter PUK")
            .keyboardDismissal()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct UnlockSIMSheet: View {
    @Bindable var viewModel: SIMViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Unlock Code (NCK)", text: $viewModel.nckInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(viewModel.lockInfo.availableTrials) attempts remaining")
                        SheetErrorFooter(message: viewModel.sheetError)
                    }
                }

                Section {
                    Button {
                        Task { await viewModel.unlockSIM() }
                    } label: {
                        Text("Unlock")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(viewModel.nckInput.isEmpty || viewModel.isLoading)
                }
            }
            .navigationTitle("SIM Unlock")
            .keyboardDismissal()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
