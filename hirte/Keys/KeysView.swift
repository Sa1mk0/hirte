import HerdrKit
import SwiftUI
import UniformTypeIdentifiers

struct KeysView: View {
    @Environment(KeyLibrary.self) private var keys
    @State private var creating = false
    @State private var importing = false

    var body: some View {
        List {
            if keys.keys.isEmpty {
                ContentUnavailableView {
                    Label("No keys", systemImage: "key")
                } description: {
                    Text("Create or import a key, then add its public key to ~/.ssh/authorized_keys on your machines.")
                } actions: {
                    Button("Create Key") { creating = true }
                    Button("Import Key") { importing = true }
                }
            }
            ForEach(keys.keys) { key in
                NavigationLink(value: key) {
                    KeyRow(key: key)
                }
            }
            .onDelete { offsets in
                offsets.map { keys.keys[$0] }.forEach(keys.delete)
            }
        }
        .navigationTitle("Keys")
        .navigationDestination(for: SSHKeyInfo.self) { KeyDetailView(key: $0) }
        .toolbar {
            Menu("New Key", systemImage: "plus") {
                Button("Create Key", systemImage: "key") { creating = true }
                    .accessibilityIdentifier("menu-create-key")
                Button("Import Key", systemImage: "square.and.arrow.down") { importing = true }
                    .accessibilityIdentifier("menu-import-key")
            }
            .accessibilityIdentifier("new-key")
        }
        .sheet(isPresented: $creating) { NewKeyView() }
        .sheet(isPresented: $importing) { ImportKeyView() }
    }
}

extension SSHKeyInfo {
    /// Where the private key lives, for people.
    var storageDescription: String {
        switch kind {
        case .secureEnclave: "Secure Enclave"
        case .software: "Keychain"
        case .securityKey: "Security key"
        }
    }

    /// e.g. "Keychain · Ed25519 · imported".
    var summary: String {
        var parts = [storageDescription, algorithmDescription]
        if isImported { parts.append("imported") }
        return parts.joined(separator: " · ")
    }

    /// A P-256 key made in the Keychain because there was no Secure Enclave (the simulator).
    var isSoftwareFallback: Bool {
        kind == .software && !isImported && algorithm == .ecdsaP256
    }
}

struct KeyRow: View {
    let key: SSHKeyInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(key.label)
                if key.requiresBiometry {
                    Image(systemName: "faceid").foregroundStyle(.secondary)
                }
                if key.kind == .securityKey {
                    Image(systemName: "key.radiowaves.forward").foregroundStyle(.secondary)
                }
            }
            if key.isSoftwareFallback {
                Text("Software key (no Secure Enclave)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text(key.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Create

struct NewKeyView: View {
    @Environment(KeyLibrary.self) private var keys
    @Environment(\.dismiss) private var dismiss
    @State private var label = UIDevice.current.name
    @State private var type: KeyLibrary.NewKeyType = .secureEnclave
    @State private var requireBiometry = false
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $label)
                } footer: {
                    Text("Shown as the comment in authorized_keys.")
                }
                Section("Type") {
                    Picker("Type", selection: $type) {
                        ForEach(KeyLibrary.NewKeyType.allCases) { type in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.title)
                                Text(type.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(type)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if type == .securityKey {
                    Section {
                        Text(WebAuthnSetup.sshdLine)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    } header: {
                        Text("Server setup")
                    } footer: {
                        Text(WebAuthnSetup.explanation)
                    }
                } else {
                    Section {
                        Toggle("Require Face ID", isOn: $requireBiometry)
                    } footer: {
                        typeFooter
                    }
                }
            }
            .navigationTitle("New Key")
            .dismissesKeyboardOnTapOutside()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Create") { create() }
                            .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(working)
            .alert("Could not create key", isPresented: .constant(keys.lastError != nil)) {
                Button("OK") { keys.lastError = nil }
            } message: {
                Text(keys.lastError ?? "")
            }
        }
    }

    @ViewBuilder private var typeFooter: some View {
        switch type {
        case .secureEnclave:
            if keys.hasSecureEnclave {
                Text("The private key is created inside the Secure Enclave and can never leave this device.")
            } else {
                Text("This device has no Secure Enclave (the simulator?). A software key will be stored in the Keychain instead.")
                    .foregroundStyle(.orange)
            }
        case .ed25519:
            Text("The private key is stored in this device's Keychain and isn't synced. Hirte asks for Face ID before using it if you turn this on.")
        case .securityKey:
            EmptyView()
        }
    }

    private func create() {
        working = true
        let label = label.trimmingCharacters(in: .whitespaces)
        Task {
            let created = await keys.generate(
                type, label: label, requireBiometry: requireBiometry && type != .securityKey)
            working = false
            if created != nil { dismiss() }
        }
    }
}

extension KeyLibrary.NewKeyType {
    var title: String {
        switch self {
        case .secureEnclave: "Secure Enclave"
        case .ed25519: "Ed25519"
        case .securityKey: "Security Key (FIDO2)"
        }
    }

    var subtitle: String {
        switch self {
        case .secureEnclave: "ECDSA P-256, never leaves this device"
        case .ed25519: "Stored in the Keychain"
        case .securityKey: "A hardware key over NFC, USB-C or Lightning"
        }
    }
}

/// What servers need before they accept a security key from Hirte.
enum WebAuthnSetup {
    static let sshdLine = "PubkeyAcceptedAlgorithms +webauthn-sk-ecdsa-sha2-nistp256@openssh.com"
    static let explanation =
        "iOS only lets apps use security keys through WebAuthn, so Hirte's signatures are of the WebAuthn kind, "
        + "which OpenSSH (8.4 or later) accepts once this line is in /etc/ssh/sshd_config. "
        + "Tap Create, then hold the key near the top of the iPhone or plug it in."
}

// MARK: - Import

struct ImportKeyView: View {
    @Environment(KeyLibrary.self) private var keys
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var passphrase = ""
    @State private var label = ""
    @State private var requireBiometry = false
    @State private var choosingFile = false
    @State private var working = false
    @State private var error: String?

    private var needsPassphrase: Bool { PrivateKeyParser.needsPassphrase(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    KeyTextView(text: $text)
                        .frame(height: 180)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("-----BEGIN OPENSSH PRIVATE KEY-----")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityIdentifier("import-key-text")
                    HStack {
                        PasteButton(payloadType: String.self) { strings in
                            if let string = strings.first { load(string, name: nil) }
                        }
                        .labelStyle(.titleAndIcon)
                        Spacer()
                        Button("Choose File", systemImage: "folder") { choosingFile = true }
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Private key")
                } footer: {
                    Text("Ed25519, ECDSA or RSA, in the OpenSSH format (as ssh-keygen writes it) or PEM.")
                }

                if needsPassphrase {
                    Section {
                        SecureField("Passphrase", text: $passphrase)
                            // Not a website password: keep iOS from offering to save it in Passwords.
                            .textContentType(.oneTimeCode)
                            .submitLabel(.done)
                            .onSubmit { if !passphrase.isEmpty { importKey() } }
                            .accessibilityIdentifier("import-key-passphrase")
                    } footer: {
                        Text("Only used to decrypt the key now. Hirte keeps the key itself, without the passphrase.")
                    }
                }

                Section {
                    TextField("Name", text: $label)
                    Toggle("Require Face ID", isOn: $requireBiometry)
                } footer: {
                    Text("The key is stored in this device's Keychain and isn't synced. "
                        + "Hirte asks for Face ID before using it if you turn this on.")
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Import Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Import") { importKey() }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || (needsPassphrase && passphrase.isEmpty))
                    }
                }
            }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url): loadFile(url)
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .onChange(of: text) { error = nil }
            .onChange(of: passphrase) { error = nil }
            .dismissesKeyboardOnTapOutside()
        }
    }

    private func load(_ string: String, name: String?) {
        text = string
        passphrase = ""
        error = nil
        if label.isEmpty, let name { label = name }
    }

    private func loadFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 64 * 1024, let string = String(data: data, encoding: .utf8) else {
                error = "That file isn't a private key."
                return
            }
            load(string, name: url.lastPathComponent)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func importKey() {
        working = true
        error = nil
        let (text, passphrase) = (text, needsPassphrase ? passphrase : nil)
        Task {
            // Deriving the key from a passphrase takes a moment; keep it off the main thread.
            let result = await Task.detached {
                Result { try PrivateKeyParser.parse(text, passphrase: passphrase) }
            }.value
            working = false
            switch result {
            case .success(let parsed):
                let name = label.trimmingCharacters(in: .whitespaces)
                let finalName = name.isEmpty ? (parsed.comment ?? parsed.algorithm.displayName) : name
                if keys.importKey(parsed, label: finalName, requireBiometry: requireBiometry) != nil {
                    dismiss()
                } else {
                    error = keys.lastError
                    keys.lastError = nil
                }
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
    }
}

// MARK: - Detail

struct KeyDetailView: View {
    @Environment(KeyLibrary.self) private var keys
    @Environment(\.dismiss) private var dismiss
    let key: SSHKeyInfo
    @State private var copied = false
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                Text(key.authorizedKeysLine)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button(copied ? "Copied" : "Copy Public Key", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = key.authorizedKeysLine
                    copied = true
                }
                ShareLink(item: key.authorizedKeysLine) {
                    Label("Share Public Key", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("Public key")
            } footer: {
                Text("Append this line to ~/.ssh/authorized_keys on each machine.")
            }

            if key.kind == .securityKey {
                Section {
                    Text(WebAuthnSetup.sshdLine)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = WebAuthnSetup.sshdLine
                    }
                } header: {
                    Text("Server setup")
                } footer: {
                    Text("Each machine's /etc/ssh/sshd_config needs this line (then reload sshd). "
                        + "Hirte asks for the security key each time it connects.")
                }
            }

            Section("Details") {
                LabeledContent("Type", value: key.algorithmDescription)
                LabeledContent("Fingerprint") {
                    Text(key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Stored in", value: key.storageDescription)
                if key.kind != .securityKey {
                    LabeledContent("Face ID", value: key.requiresBiometry ? "Required" : "Not required")
                }
                LabeledContent(key.isImported ? "Imported" : "Created",
                               value: key.createdAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section {
                Button("Delete Key", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(key.label)
        .confirmationDialog("Delete “\(key.label)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                keys.delete(key)
                dismiss()
            }
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteMessage: String {
        switch key.kind {
        case .securityKey:
            "Hirte forgets this key. The security key itself is unchanged, but Hirte can't use it for this key again."
        case .software where key.isImported:
            "Hirte's copy of the private key is deleted. Copies elsewhere aren't affected."
        default:
            "The private key is destroyed. Machines that only trust this key will lock you out."
        }
    }
}
