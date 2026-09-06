import AppKit

private extension NSPasteboard.PasteboardType {
    static let zoneBlock = NSPasteboard.PasteboardType(
        "com.arunmeyer.WindowMangerDeClaude.zoneblock")
}

final class SnapZoneConfigView: NSView {
    private let profilePopup = NSPopUpButton()
    private let deleteButton = NSButton()
    private var slotViews: [SnapZoneSlotView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        buildView()
        NotificationCenter.default.addObserver(
            self, selector: #selector(snapZonesChanged),
            name: .snapZonesDidChange, object: nil)
        reloadProfiles()
        reloadSlots()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func buildView() {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        let header = profileHeader()
        let slots = slotRow()
        let inventory = inventory()
        content.addArrangedSubview(header)
        content.addArrangedSubview(slots)
        content.addArrangedSubview(inventory)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -18),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            slots.widthAnchor.constraint(equalTo: content.widthAnchor),
            inventory.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
    }

    private func profileHeader() -> NSView {
        profilePopup.target = self
        profilePopup.action = #selector(profileSelected(_:))
        profilePopup.translatesAutoresizingMaskIntoConstraints = false
        profilePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true

        let save = NSButton(title: L("snapZones.save"), target: self, action: #selector(saveProfile))
        save.bezelStyle = .rounded

        deleteButton.title = L("snapZones.delete")
        deleteButton.target = self
        deleteButton.action = #selector(deleteProfile)
        deleteButton.bezelStyle = .rounded

        let profileRow = NSStackView(views: [profilePopup, save, deleteButton])
        profileRow.orientation = .horizontal
        profileRow.alignment = .centerY
        profileRow.spacing = 8

        let reset = NSButton(title: L("snapZones.reset"), target: self, action: #selector(resetSlots))
        reset.bezelStyle = .rounded
        reset.keyEquivalent = ""

        // Zwei kompakte Zeilen lassen die langen deutschen Titel auch bei der
        // kleinsten vorgesehenen Inhaltsbreite vollstaendig lesbar.
        let header = NSStackView(views: [profileRow, reset])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        return header
    }

    private func slotRow() -> NSView {
        var wrappers: [NSView] = []
        for index in 0..<SnapZoneDefaults.slotCount {
            let slot = SnapZoneSlotView(index: index)
            slot.translatesAutoresizingMaskIntoConstraints = false
            slot.heightAnchor.constraint(equalTo: slot.widthAnchor, multiplier: 0.7).isActive = true
            slotViews.append(slot)

            let number = NSTextField(labelWithString: String(index + 1))
            number.font = .systemFont(ofSize: 11, weight: .medium)
            number.textColor = .secondaryLabelColor
            number.alignment = .center

            let wrapper = NSStackView(views: [slot, number])
            wrapper.orientation = .vertical
            wrapper.alignment = .centerX
            wrapper.spacing = 4
            slot.widthAnchor.constraint(equalTo: wrapper.widthAnchor).isActive = true
            wrappers.append(wrapper)
        }

        let row = NSStackView(views: wrappers)
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func inventory() -> NSView {
        let title = NSTextField(labelWithString: L("snapZones.inventory"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let chips = ZoneBlock.allCases.map { block -> NSView in
            let chip = ZoneBlockChipView(block: block)
            chip.translatesAutoresizingMaskIntoConstraints = false
            chip.widthAnchor.constraint(equalToConstant: 72).isActive = true
            chip.heightAnchor.constraint(equalToConstant: 50).isActive = true

            let label = NSTextField(labelWithString: L(block.localizationKey))
            label.font = .systemFont(ofSize: 10)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail

            let wrapper = NSStackView(views: [chip, label])
            wrapper.orientation = .vertical
            wrapper.alignment = .centerX
            wrapper.spacing = 5
            return wrapper
        }

        let chipRow = NSStackView(views: chips)
        chipRow.orientation = .horizontal
        chipRow.alignment = .top
        chipRow.distribution = .equalSpacing
        chipRow.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(wrappingLabelWithString: L("snapZones.hint"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2

        let box = NSStackView(views: [title, chipRow, hint])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 10
        box.translatesAutoresizingMaskIntoConstraints = false
        chipRow.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
        hint.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
        return box
    }

    @objc private func snapZonesChanged() {
        reloadSlots()
    }

    private func reloadSlots() {
        slotViews.forEach { $0.reload() }
    }

    private func reloadProfiles(selecting name: String? = nil) {
        profilePopup.removeAllItems()
        let profiles = SnapZoneStore.shared.profiles
        if profiles.isEmpty {
            profilePopup.addItem(withTitle: L("snapZones.profile.none"))
            profilePopup.lastItem?.isEnabled = false
            profilePopup.isEnabled = false
        } else {
            profilePopup.addItems(withTitles: profiles.map(\.name))
            profilePopup.isEnabled = true
            if let name, let index = profiles.firstIndex(where: { $0.name == name }) {
                profilePopup.selectItem(at: index)
            }
        }
        deleteButton.isEnabled = !profiles.isEmpty
    }

    @objc private func profileSelected(_ sender: NSPopUpButton) {
        guard let name = sender.selectedItem?.title else { return }
        _ = SnapZoneStore.shared.applyProfile(named: name)
    }

    @objc private func saveProfile() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = L("snapZones.save.prompt")

        let alert = NSAlert()
        alert.messageText = L("snapZones.save.prompt")
        alert.accessoryView = field
        alert.addButton(withTitle: L("snapZones.save"))
        alert.addButton(withTitle: L("snapZones.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if SnapZoneStore.shared.saveProfile(named: name) {
            reloadProfiles(selecting: name)
        } else {
            let limit = NSAlert()
            limit.alertStyle = .warning
            limit.messageText = L("snapZones.save.limit")
            limit.runModal()
        }
    }

    @objc private func deleteProfile() {
        guard let name = profilePopup.selectedItem?.title, profilePopup.isEnabled else { return }
        SnapZoneStore.shared.deleteProfile(named: name)
        reloadProfiles()
    }

    @objc private func resetSlots() {
        SnapZoneStore.shared.resetToFactory()
    }
}

private extension ZoneBlock {
    var localizationKey: String {
        switch self {
        case .full: return "block.full"
        case .twoThirds: return "block.twoThirds"
        case .half: return "block.half"
        case .third: return "block.third"
        case .quarter: return "block.quarter"
        }
    }

    var previewRect: CGRect {
        switch self {
        case .full: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .twoThirds: return CGRect(x: 0, y: 0, width: 2.0 / 3.0, height: 1)
        case .half: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .third: return CGRect(x: 0, y: 0, width: 1.0 / 3.0, height: 1)
        case .quarter: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        }
    }
}

private final class ZoneBlockChipView: NSView, NSDraggingSource {
    private let block: ZoneBlock

    init(block: ZoneBlock) {
        self.block = block
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let tokens = DesignTokens.current()
        let screen = bounds.insetBy(dx: 2, dy: 2)
        let background = NSBezierPath(roundedRect: screen, xRadius: 7, yRadius: 7)
        tokens.layoutBg.setFill()
        background.fill()
        tokens.zoneEdge.setStroke()
        background.lineWidth = 0.75
        background.stroke()

        let area = screen.insetBy(dx: 6, dy: 6)
        let unit = block.previewRect
        let rect = CGRect(x: area.minX + unit.minX * area.width,
                          y: area.minY + unit.minY * area.height,
                          width: unit.width * area.width,
                          height: unit.height * area.height).insetBy(dx: 1, dy: 1)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        tokens.accent.withAlphaComponent(0.72).setFill()
        shape.fill()
    }

    override func mouseDown(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(block.rawValue, forType: .zoneBlock)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: dragImage())
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func dragImage() -> NSImage {
        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSImage(size: bounds.size)
        }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

private final class SnapZoneSlotView: NSView {
    private enum DropState: Equatable { case none, valid, invalid }

    private let index: Int
    private var dropState: DropState = .none
    private var hoveredBlockIndex: Int?
    private var tracking: NSTrackingArea?

    init(index: Int) {
        self.index = index
        super.init(frame: .zero)
        registerForDraggedTypes([.zoneBlock])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private var blocks: [ZoneBlock] {
        let slots = SnapZoneStore.shared.slots
        return slots.indices.contains(index) ? slots[index] : []
    }

    private var drawingArea: CGRect { bounds.insetBy(dx: 9, dy: 9) }

    func reload() {
        dropState = .none
        hoveredBlockIndex = nil
        needsDisplay = true
    }

    private func blockRects() -> [CGRect] {
        guard let placed = SnapSlotPacker.pack(blocks) else { return [] }
        let area = drawingArea
        return placed.map { placedBlock in
            let unit = placedBlock.rect
            return CGRect(x: area.minX + unit.minX * area.width,
                          y: area.minY + unit.minY * area.height,
                          width: max(3, unit.width * area.width),
                          height: max(3, unit.height * area.height)).insetBy(dx: 1.5, dy: 1.5)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let tokens = DesignTokens.current()
        let backgroundRect = bounds.insetBy(dx: 2, dy: 2)
        let background = NSBezierPath(roundedRect: backgroundRect, xRadius: 10, yRadius: 10)
        tokens.layoutBg.setFill()
        background.fill()

        let outline: NSColor
        switch dropState {
        case .none: outline = tokens.zoneEdge
        case .valid: outline = tokens.accent
        case .invalid: outline = .systemRed
        }
        outline.setStroke()
        background.lineWidth = dropState == .none ? 0.75 : 2
        if blocks.isEmpty, dropState == .none {
            let dash: [CGFloat] = [5, 4]
            background.setLineDash(dash, count: dash.count, phase: 0)
        }
        background.stroke()

        if blocks.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let text = L("snapZones.slot.empty") as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: bounds.midX - size.width / 2,
                                  y: bounds.midY - size.height / 2),
                      withAttributes: attributes)
            return
        }

        for (blockIndex, rect) in blockRects().enumerated() {
            let shape = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            if hoveredBlockIndex == blockIndex {
                tokens.accent.setFill()
            } else {
                tokens.zoneFill.setFill()
            }
            shape.fill()
            if hoveredBlockIndex == blockIndex {
                tokens.accent.setStroke()
                shape.lineWidth = 1.5
                shape.stroke()
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let next = blockRects().firstIndex(where: { $0.contains(point) })
        if next != hoveredBlockIndex {
            hoveredBlockIndex = next
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredBlockIndex = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let blockIndex = blockRects().firstIndex(where: { $0.contains(point) }) else { return }

        // Die Spezifikation nennt keinen Rueckweg. Entfernen per Klick verhindert,
        // dass ein einmal gefuellter Slot nur ueber den Werksreset korrigierbar ist.
        var slots = SnapZoneStore.shared.slots
        guard slots.indices.contains(index), slots[index].indices.contains(blockIndex) else { return }
        slots[index].remove(at: blockIndex)
        SnapZoneStore.shared.slots = slots
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropState(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropState(sender)
    }

    private func updateDropState(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let block = draggedBlock(from: sender) else {
            setDropState(.invalid)
            return []
        }
        if SnapSlotPacker.canAppend(block, to: blocks) {
            setDropState(.valid)
            return .copy
        }
        setDropState(.invalid)
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let block = draggedBlock(from: sender),
              SnapSlotPacker.canAppend(block, to: blocks) else { return false }
        var slots = SnapZoneStore.shared.slots
        guard slots.indices.contains(index) else { return false }
        slots[index].append(block)
        SnapZoneStore.shared.slots = slots
        setDropState(.none)
        return true
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropState(.none)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDropState(.none)
    }

    private func draggedBlock(from sender: NSDraggingInfo) -> ZoneBlock? {
        guard let raw = sender.draggingPasteboard.string(forType: .zoneBlock) else { return nil }
        return ZoneBlock(rawValue: raw)
    }

    private func setDropState(_ state: DropState) {
        dropState = state
        needsDisplay = true
    }
}
