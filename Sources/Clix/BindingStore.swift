import Combine
import Foundation
import os

let log = Logger(subsystem: "com.digigara.Clix", category: "clix")

/// The persisted set of button bindings plus the master on/off switch.
///
/// Bindings live in `~/Library/Application Support/Clix/bindings.json` so they
/// survive a rebuild of the app bundle.
final class BindingStore: ObservableObject {
    @Published private(set) var bindings: [Int: InputBinding] = [:]
    @Published var isEnabled = true { didSet { save() } }
    /// Suppresses the write that `isEnabled`'s observer would otherwise trigger
    /// while the stored file is being read back in.
    private var isLoading = false
    /// The buttons shown in the sidebar. Seeded with a common set on first
    /// run, then entirely the user's to add to and delete from.
    @Published private(set) var buttons: [Int] = MouseButton.standard
    /// Gesture bindings, keyed by `TrackpadGesture.id`.
    @Published private(set) var gestureBindings: [String: InputBinding] = [:]
    /// The gestures shown in the sidebar. Empty until the user adds one.
    @Published private(set) var gestures: [TrackpadGesture] = []
    /// The most recent gesture recognised, for the "add" sheet.
    @Published private(set) var lastSeenGesture: TrackpadGesture?
    /// The most recent button the tap has seen, so the UI can highlight its
    /// row and the "add button" sheet can fill itself in.
    @Published private(set) var lastSeenButton: Int?
    /// A one-line note about the most recent press, shown in Settings so it is
    /// obvious whether Clix is receiving clicks at all. Not persisted.
    @Published var lastActivity: String?
    /// Set while the "add button" sheet is open. Presses are still swallowed,
    /// so a click cannot leak into the app behind, but bound actions are held
    /// back — identifying a button should not also quit your editor.
    @Published var isDetecting = false

    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("Clix", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("bindings.json")
        load()
    }

    func action(for button: Int) -> Action? { bindings[button]?.action }

    // MARK: - Targets

    func binding(for target: BindingTarget) -> InputBinding? {
        switch target {
        case .button(let number): return bindings[number]
        case .gesture(let gesture): return gestureBindings[gesture.id]
        }
    }

    func action(for target: BindingTarget) -> Action? { binding(for: target)?.action }

    func setBinding(_ binding: InputBinding?, for target: BindingTarget) {
        switch target {
        case .button(let number):
            guard number >= MouseButton.lowestBindable else { return }
            bindings[number] = binding
        case .gesture(let gesture):
            gestureBindings[gesture.id] = binding
        }
        save()
    }

    func remove(_ target: BindingTarget) {
        switch target {
        case .button(let number): removeButton(number)
        case .gesture(let gesture): removeGesture(gesture)
        }
    }

    /// What to select once `target` has been deleted.
    func neighbour(of target: BindingTarget) -> BindingTarget? {
        let all = listedTargets
        guard let index = all.firstIndex(of: target) else { return all.first }
        if index + 1 < all.count { return all[index + 1] }
        return index > 0 ? all[index - 1] : nil
    }

    var listedTargets: [BindingTarget] {
        buttons.map(BindingTarget.button) + gestures.map(BindingTarget.gesture)
    }

    // MARK: - Gestures

    var addableGestures: [TrackpadGesture] {
        TrackpadGesture.supported.filter { !gestures.contains($0) }
    }

    @discardableResult
    func addGesture(_ gesture: TrackpadGesture) -> Bool {
        guard !gestures.contains(gesture) else { return false }
        gestures = Self.ordered(gestures + [gesture])
        save()
        return true
    }

    /// By finger count, then by motion, so the sidebar reads the same however
    /// the list was built up.
    private static func ordered(_ gestures: some Sequence<TrackpadGesture>) -> [TrackpadGesture] {
        gestures.sorted { ($0.fingers, $0.motion.rawValue) < ($1.fingers, $1.motion.rawValue) }
    }

    func removeGesture(_ gesture: TrackpadGesture) {
        guard let index = gestures.firstIndex(of: gesture) else { return }
        gestures.remove(at: index)
        gestureBindings[gesture.id] = nil
        if lastSeenGesture == gesture { lastSeenGesture = nil }
        save()
    }

    func noteSeen(gesture: TrackpadGesture) {
        lastSeenGesture = gesture
    }

    // MARK: - Managing the list

    /// Whether `number` can be added: in range, and not already listed.
    func canAdd(button number: Int) -> Bool {
        MouseButton.bindableRange.contains(number) && !buttons.contains(number)
    }

    @discardableResult
    func addButton(_ number: Int) -> Bool {
        guard canAdd(button: number) else { return false }
        buttons.append(number)
        buttons.sort()
        save()
        return true
    }

    /// Removes a button from the list along with whatever it was bound to.
    func removeButton(_ number: Int) {
        guard let index = buttons.firstIndex(of: number) else { return }
        buttons.remove(at: index)
        bindings[number] = nil
        if lastSeenButton == number { lastSeenButton = nil }
        save()
    }

    /// Every button not already listed, which is what the "add" sheet offers.
    var addableButtons: [Int] {
        MouseButton.bindableRange.filter { !buttons.contains($0) }
    }

    /// Puts the starting set back, keeping anything already listed. The way
    /// out of an emptied list.
    func restoreDefaults() {
        buttons = Set(buttons).union(MouseButton.standard).sorted()
        save()
    }

    /// The button that should be selected after `number` is deleted.
    func neighbour(of number: Int) -> Int? {
        guard let index = buttons.firstIndex(of: number) else { return buttons.first }
        if index + 1 < buttons.count { return buttons[index + 1] }
        return index > 0 ? buttons[index - 1] : nil
    }

    /// Records a press seen by the tap. This never adds a row: the list is
    /// the user's, so a button they deleted stays deleted until they add it
    /// back deliberately.
    func noteSeen(button: Int) {
        guard MouseButton.bindableRange.contains(button) else { return }
        lastSeenButton = button
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        var isEnabled: Bool
        var bindings: [String: InputBinding]
        /// Absent in files written before the list became editable.
        var buttons: [Int]?
        var gestures: [String]?
        var gestureBindings: [String: InputBinding]?
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: data)
            isEnabled = stored.isEnabled
            bindings = Dictionary(uniqueKeysWithValues: stored.bindings.compactMap { key, value in
                Int(key).map { ($0, value) }
            })
            // A file from before the list was editable has no button list; fall
            // back to the default set so nothing the user configured vanishes.
            let listed = stored.buttons ?? MouseButton.standard
            buttons = Set(listed).union(bindings.keys).sorted()
            gestureBindings = stored.gestureBindings ?? [:]
            let listedGestures = (stored.gestures ?? []).compactMap(TrackpadGesture.init(id:))
            gestures = Self.ordered(
                Set(listedGestures)
                    .union(gestureBindings.keys.compactMap(TrackpadGesture.init(id:)))
            )
        } catch {
            log.error("Could not read bindings: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        guard !isLoading else { return }
        let stored = Stored(
            isEnabled: isEnabled,
            bindings: Dictionary(uniqueKeysWithValues: bindings.map { (String($0.key), $0.value) }),
            buttons: buttons,
            gestures: gestures.map(\.id),
            gestureBindings: gestureBindings
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(stored).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Could not save bindings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
