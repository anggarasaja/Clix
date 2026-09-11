import AppKit
import ApplicationServices
import SwiftUI

/// The whole of Clix's interface: a list of mouse buttons and trackpad
/// gestures on the left, an editor for the selected one on the right.
struct SettingsView: View {
    @ObservedObject var store: BindingStore
    @ObservedObject var accessibility: AccessibilityMonitor
    @ObservedObject var tap: MouseEventTap
    @ObservedObject var trackpad: TrackpadMonitor

    @State private var selection: BindingTarget?
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?
    @State private var isAdding = false
    @State private var pendingRemoval: BindingTarget?

    var body: some View {
        Group {
            if accessibility.isTrusted {
                main
            } else {
                PermissionGate(accessibility: accessibility)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var main: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                editor.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .onAppear { if selection == nil { selection = store.listedTargets.first } }
        .onChange(of: store.lastSeenButton) { seen in
            if let seen, store.buttons.contains(seen) { selection = .button(seen) }
        }
        .sheet(isPresented: $isAdding) {
            AddTargetSheet(store: store, trackpad: trackpad) { added in selection = added }
        }
        .confirmationDialog(
            pendingRemoval.map { "Remove \($0.title)?" } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil },
                                 set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let pendingRemoval { remove(pendingRemoval) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(pendingRemoval.flatMap { store.action(for: $0) } == nil
                 ? "You can add it back at any time."
                 : "Its binding will be deleted.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            if store.listedTargets.isEmpty {
                VStack(spacing: 10) {
                    Text("Nothing mapped").foregroundStyle(.secondary)
                    Button("Add…") { isAdding = true }
                    Button("Restore Defaults") { store.restoreDefaults() }
                        .buttonStyle(.link)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
            } else {
                List(selection: $selection) {
                    if !store.buttons.isEmpty {
                        Section("Mouse Buttons") {
                            ForEach(store.buttons, id: \.self) { button in
                                row(for: .button(button))
                            }
                        }
                    }
                    if !store.gestures.isEmpty {
                        Section("Trackpad Gestures") {
                            ForEach(store.gestures) { gesture in
                                row(for: .gesture(gesture))
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onDeleteCommand {
                    if let selection { pendingRemoval = selection }
                }
            }

            Divider()
            HStack(spacing: 2) {
                Button { isAdding = true } label: {
                    Image(systemName: "plus").frame(width: 22, height: 20)
                }
                .help("Add a mouse button or trackpad gesture")

                Button {
                    if let selection { pendingRemoval = selection }
                } label: {
                    Image(systemName: "minus").frame(width: 22, height: 20)
                }
                .disabled(selection == nil)
                .help("Remove the selected item")

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(width: 230)
    }

    private func row(for target: BindingTarget) -> some View {
        HStack(spacing: 10) {
            Image(systemName: target.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.title)
                Text(store.action(for: target)?.summary ?? "Not bound")
                    .font(.caption)
                    .foregroundStyle(store.action(for: target) == nil ? .tertiary : .secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .tag(target)
        .contextMenu {
            Button("Remove \(target.title)", role: .destructive) { pendingRemoval = target }
        }
    }

    private func remove(_ target: BindingTarget) {
        let next = store.neighbour(of: target)
        store.remove(target)
        if selection == target { selection = next }
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        if let selection {
            TargetEditor(store: store, target: selection)
                .id(selection)
        } else {
            Text("Select something on the left").foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("Enable Clix", isOn: $store.isEnabled)
                .toggleStyle(.switch)

            Divider().frame(height: 16)

            HStack(spacing: 6) {
                Circle()
                    .fill(tap.isRunning ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 0) {
                    Text(statusTitle).font(.caption)
                    Text(store.lastActivity ?? statusDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let loginItemError {
                Text(loginItemError).font(.caption).foregroundStyle(.orange)
            }
            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin },
                set: { wanted in
                    if let error = LoginItem.setEnabled(wanted) {
                        loginItemError = "Could not change login item: \(error.localizedDescription)"
                        launchAtLogin = LoginItem.isEnabled
                    } else {
                        loginItemError = nil
                        launchAtLogin = wanted
                    }
                }
            ))
            .toggleStyle(.checkbox)
        }
        .padding(12)
    }

    private var statusTitle: String {
        switch (tap.isRunning, trackpad.isRunning) {
        case (true, true): return "Listening to mouse and trackpad"
        case (true, false): return "Listening for clicks"
        case (false, true): return "Listening to trackpad only"
        case (false, false): return "Not listening"
        }
    }

    private var statusDetail: String {
        if !tap.isRunning { return "Clicks are not being intercepted" }
        if tap.placement == .session {
            return "Reading clicks at the session tap — actions may wait for the button to come up"
        }
        if trackpad.isRunning && !trackpad.hasSeenContact {
            return "No trackpad contact seen yet"
        }
        return "Nothing seen yet"
    }
}

// MARK: - Permission gate

/// Shown in place of the whole interface, because without Accessibility
/// nothing in Clix functions: clicks are not intercepted and keystrokes
/// cannot be sent.
private struct PermissionGate: View {
    @ObservedObject var accessibility: AccessibilityMonitor

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(.orange)

            Text("Clix needs Accessibility access")
                .font(.title2.weight(.semibold))

            Text("""
                 Without it Clix cannot see your mouse buttons and cannot send \
                 keystrokes, so no binding will do anything at all. macOS gives \
                 no error when this is missing — actions simply do nothing.
                 """)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)

            HStack {
                Button("Open System Settings") { accessibility.openSettings() }
                    .keyboardShortcut(.defaultAction)
                Button("Show the Prompt Again") { accessibility.requestAccess() }
            }

            Text("""
                 In Privacy & Security → Accessibility, switch Clix on. If Clix \
                 is already listed after a rebuild, remove it with − and add \
                 /Applications/Clix.app again — an updated build no longer \
                 matches the old entry. This screen disappears by itself once \
                 access is granted.
                 """)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

// MARK: - Editor

private struct TargetEditor: View {
    @ObservedObject var store: BindingStore
    let target: BindingTarget

    @State private var isBound: Bool
    @State private var kind: ActionKind
    @State private var combo: KeyCombo?
    @State private var app: AppTarget?
    @State private var systemAction: SystemAction
    @State private var gesture: TrackpadGesture
    @State private var urlString: String
    @State private var command: String
    @State private var trigger: ActionTrigger
    @State private var recorderIsDegraded = false

    init(store: BindingStore, target: BindingTarget) {
        self.store = store
        self.target = target
        let binding = store.binding(for: target)
        let action = binding?.action
        _isBound = State(initialValue: binding != nil)
        _kind = State(initialValue: action?.kind ?? .keyCombo)
        _trigger = State(initialValue: binding?.trigger ?? .press)
        _systemAction = State(initialValue: .missionControl)
        _gesture = State(initialValue: TrackpadGesture(fingers: 4, motion: .left))
        _urlString = State(initialValue: "")
        _command = State(initialValue: "")

        switch action {
        case .keyCombo(let value): _combo = State(initialValue: value)
        case .launchApp(let value): _app = State(initialValue: value)
        case .system(let value): _systemAction = State(initialValue: value)
        case .trackpadGesture(let value): _gesture = State(initialValue: value)
        case .openURL(let value): _urlString = State(initialValue: value)
        case .shell(let value): _command = State(initialValue: value)
        default: break
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if isBound {
                    Picker("Action", selection: $kind) {
                        ForEach(ActionKind.allCases) { kind in
                            Label(kind.title, systemImage: kind.symbol).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 280, alignment: .leading)

                    Divider()
                    detail

                    // A gesture is recognised once, when the fingers lift, so
                    // there is no press and release to choose between.
                    if case .button = target {
                        Divider()
                        triggerPicker
                    }

                    if let action = store.action(for: target) {
                        Divider()
                        HStack(spacing: 10) {
                            Button("Test Action") { ActionRunner.perform(action) }
                            Text("Runs it now, without the mouse — so you can tell a broken action from an input that never arrived.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: isBound) { _ in commit() }
        .onChange(of: kind) { _ in commit() }
        .onChange(of: combo) { _ in commit() }
        .onChange(of: app) { _ in commit() }
        .onChange(of: systemAction) { _ in commit() }
        .onChange(of: gesture) { _ in commit() }
        .onChange(of: urlString) { _ in commit() }
        .onChange(of: command) { _ in commit() }
        .onChange(of: trigger) { _ in commit() }
    }

    private var triggerPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("When it fires").font(.subheadline.weight(.medium))
            Picker("When it fires", selection: $trigger) {
                ForEach(ActionTrigger.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280, alignment: .leading)
            Text(trigger.note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(target.title).font(.title2.weight(.semibold))
            Toggle("Map this input", isOn: $isBound).toggleStyle(.switch)
            Text(isBound ? target.interceptionNote : "It behaves exactly as it normally would.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if case .gesture(let gesture) = target, let conflict = gesture.systemConflict {
                Label(conflict, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch kind {
        case .keyCombo:
            VStack(alignment: .leading, spacing: 8) {
                Text("Shortcut to send").font(.subheadline.weight(.medium))
                HStack {
                    ShortcutRecorder(combo: $combo, isDegraded: $recorderIsDegraded)
                        .frame(width: 220, height: 30)
                    Button("Clear") { combo = nil }.disabled(combo == nil)
                }
                Text("Click the field, then press the combination — including ones macOS reserves, such as ⌃← or ⌘Space. ⎋ cancels, ⌫ clears.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if recorderIsDegraded {
                    Label("Could not capture keys. Grant Accessibility access and relaunch Clix.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

        case .launchApp:
            VStack(alignment: .leading, spacing: 8) {
                Text("Application to open").font(.subheadline.weight(.medium))
                HStack(spacing: 10) {
                    if let app, let icon = app.icon {
                        Image(nsImage: icon).resizable().frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                    }
                    Text(app?.name ?? "No app chosen")
                        .foregroundStyle(app == nil ? .secondary : .primary)
                    Button("Choose…") { chooseApp() }
                }
            }

        case .system:
            VStack(alignment: .leading, spacing: 8) {
                Text("Function").font(.subheadline.weight(.medium))
                Picker("Function", selection: $systemAction) {
                    ForEach(SystemAction.Group.allCases) { group in
                        Section(group.rawValue) {
                            ForEach(group.members) { action in
                                Text(action.title).tag(action)
                            }
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)
                if let note = systemAction.note {
                    Text(note).font(.caption).foregroundStyle(.secondary).frame(maxWidth: 380, alignment: .leading)
                }
            }

        case .trackpadGesture:
            VStack(alignment: .leading, spacing: 8) {
                Text("Gesture to stand in for").font(.subheadline.weight(.medium))
                Picker("Gesture", selection: $gesture) {
                    ForEach(TrackpadGesture.performable) { item in
                        Text(item.title).tag(item)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)
                Text(gestureNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 400, alignment: .leading)
            }

        case .openURL:
            VStack(alignment: .leading, spacing: 8) {
                Text("URL to open").font(.subheadline.weight(.medium))
                TextField("example.com", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 380)
                Text("Opens in your default browser. Custom schemes such as raycast:// work too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .shell:
            VStack(alignment: .leading, spacing: 8) {
                Text("Shell command").font(.subheadline.weight(.medium))
                TextEditor(text: $command)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: 380, minHeight: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                Text("Run with zsh -lc, detached. Output is not shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .block:
            Text("The input is intercepted and discarded. Useful for a button your mouse fires by accident.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380, alignment: .leading)
        }
    }

    /// Spells out what the button will actually do, because a gesture's name
    /// and its effect are not the same thing — a four finger swipe left moves
    /// one space to the *right*.
    private var gestureNote: String {
        guard let effect = gesture.systemEffect else { return "" }
        return """
               Does what the gesture does: \(effect.title). macOS has no public \
               way to inject finger contacts, so Clix reproduces the effect \
               rather than the contacts — for the space and App Exposé \
               gestures that means sending the shortcut macOS assigns them, \
               which has to stay enabled in Keyboard Settings.
               """
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app = AppTarget(url: url)
    }

    private func commit() {
        guard isBound else {
            store.setBinding(nil, for: target)
            return
        }
        let action: Action?
        switch kind {
        case .keyCombo: action = combo.map(Action.keyCombo)
        case .launchApp: action = app.map(Action.launchApp)
        case .system: action = .system(systemAction)
        case .trackpadGesture: action = .trackpadGesture(gesture)
        case .openURL: action = .openURL(urlString)
        case .shell: action = .shell(command)
        case .block: action = .block
        }
        // An incomplete choice stores nothing, so the input keeps working
        // normally until the binding is actually finished.
        store.setBinding(action.map { InputBinding(action: $0, trigger: trigger) }, for: target)
    }
}

// MARK: - Adding

/// Adds a mouse button or a trackpad gesture, by choosing from a list or by
/// performing it.
private struct AddTargetSheet: View {
    @ObservedObject var store: BindingStore
    @ObservedObject var trackpad: TrackpadMonitor
    var onAdd: (BindingTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isGesture = false
    @State private var buttonChoice: Int?
    @State private var gestureChoice: TrackpadGesture?
    @State private var detected: String?
    @State private var note: String?
    @State private var canDetectButton = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add an Input").font(.headline)

            Picker("", selection: $isGesture) {
                Text("Mouse Button").tag(false)
                Text("Trackpad Gesture").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if isGesture { gestureSection } else { buttonSection }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isGesture ? gestureChoice == nil : buttonChoice == nil)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            buttonChoice = store.addableButtons.first
            gestureChoice = store.addableGestures.first
            canDetectButton = AXIsProcessTrusted() && store.isEnabled
            store.isDetecting = true
        }
        .onDisappear { store.isDetecting = false }
        .onChange(of: store.lastSeenButton) { seen in
            guard let seen, !isGesture else { return }
            detected = MouseButton.name(for: seen)
            if store.buttons.contains(seen) {
                note = "\(MouseButton.name(for: seen)) is already in the list."
            } else {
                note = nil
                buttonChoice = seen
            }
        }
        .onChange(of: store.lastSeenGesture) { seen in
            guard let seen, isGesture else { return }
            detected = seen.title
            if store.gestures.contains(seen) {
                note = "\(seen.title) is already in the list."
            } else {
                note = nil
                gestureChoice = seen
            }
        }
        .onChange(of: isGesture) { _ in
            detected = nil
            note = nil
        }
    }

    @ViewBuilder
    private var buttonSection: some View {
        if store.addableButtons.isEmpty {
            Text("Every button Clix supports is already in the list.")
                .foregroundStyle(.secondary)
        } else {
            Picker("Button", selection: $buttonChoice) {
                ForEach(store.addableButtons, id: \.self) { button in
                    Text(MouseButton.name(for: button)).tag(Int?.some(button))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240, alignment: .leading)

            detectionBox(
                prompt: "Or press the button on your mouse",
                available: canDetectButton,
                unavailable: "Needs Accessibility access. Use the list above."
            )
            Text(note ?? "Left and right click cannot be remapped.")
                .font(.caption)
                .foregroundStyle(note == nil ? Color.secondary : Color.orange)
        }
    }

    @ViewBuilder
    private var gestureSection: some View {
        if store.addableGestures.isEmpty {
            Text("Every gesture Clix supports is already in the list.")
                .foregroundStyle(.secondary)
        } else {
            Picker("Gesture", selection: $gestureChoice) {
                ForEach(store.addableGestures) { gesture in
                    Text(gesture.title).tag(TrackpadGesture?.some(gesture))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240, alignment: .leading)

            detectionBox(
                prompt: "Or perform the gesture on your trackpad",
                available: trackpad.isRunning,
                unavailable: "No trackpad found, or Clix is switched off."
            )
            Text(note ?? gestureHint)
                .font(.caption)
                .foregroundStyle(note == nil ? Color.secondary : Color.orange)
        }
    }

    private var gestureHint: String {
        if trackpad.isRunning && !trackpad.hasSeenContact {
            return "No trackpad contact seen yet. macOS may require Input Monitoring access for this."
        }
        return "Three, four and five finger taps and swipes."
    }

    private func detectionBox(prompt: String, available: Bool, unavailable: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prompt).font(.subheadline.weight(.medium))
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                RoundedRectangle(cornerRadius: 8)
                    .stroke(detected == nil ? Color.secondary.opacity(0.3) : Color.accentColor,
                            lineWidth: detected == nil ? 1 : 2)
                if !available {
                    Label(unavailable, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                } else if let detected {
                    Text(detected).fontWeight(.medium)
                } else {
                    Text("Waiting…").foregroundStyle(.secondary)
                }
            }
            .frame(height: 54)
        }
    }

    private func add() {
        if isGesture {
            guard let gestureChoice, store.addGesture(gestureChoice) else { return }
            onAdd(.gesture(gestureChoice))
        } else {
            guard let buttonChoice, store.addButton(buttonChoice) else { return }
            onAdd(.button(buttonChoice))
        }
        dismiss()
    }
}
