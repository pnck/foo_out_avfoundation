//
//  preferences_view_controller.swift
//  foo_out_avfoundation
//
//  The component's preferences page for the virtual speaker rig. A mode switch, a top-down stage where
//  you drag the front pair, rear pair, mono centre and LFE around the listener, sliders for the
//  per-pair spacing/elevation, mono height, and per-group gain, plus a live SceneKit preview.
//
//  Editing is a PREVIEW transaction: every edit updates the working layout, the on-screen preview, AND
//  the running engine live (you hear the field move) — but nothing is persisted. Leaving the page
//  without Save drops the preview, so the engine reverts to the saved layout. "Save" commits the whole
//  layout + the Virtual 3D switch (the mode change applies on the next playback start). "Reset" loads
//  the standard 5.1 layout into the editor.
//
//  @objc name is fixed; preferences_page.mm resolves the controller by it (NSClassFromString).
//

import AppKit

@objc(V3DPreferencesViewController)
final class V3DPreferencesViewController: NSViewController {

    // Half-extent of the stage in metres (pad edge = RANGE m from the listener).
    private let range: CGFloat = 4.0

    // Working (unsaved) layout. Mirrors v3d_config::Layout; committed to V3DConfig only on Save.
    private var v3dEnabled = false
    private var frontDist = 2.0, frontSpacing = 60.0, frontAz = 0.0, frontEl = 0.0
    private var rearDist = 2.0, rearSpacing = 140.0, rearAz = 180.0, rearEl = 0.0
    private var centerX = 0.0, centerY = 0.0, centerZ = -2.0
    private var lfeX = 0.0, lfeY = -0.4, lfeZ = -1.5
    private var frontGainDb = 0.0, rearGainDb = 0.0, centerGainDb = 0.0, lfeGainDb = 0.0

    private let modeToggle = NSButton(checkboxWithTitle: "Enable Virtual 3D (custom speaker rig)",
                                      target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let stage = StageView()
    private let scene = SceneRigView()

    // Manual-layout scaffolding (no Auto Layout): the scrollable form lives in `docView`, every form
    // entry is (view, fixed-height) in `formItems`, positioned by frame in relayout().
    private let scrollView = NSScrollView()
    private let docView = FlippedView()
    private var stageLabel = NSTextField()
    private var sceneLabel = NSTextField()
    private var formItems: [(NSView, CGFloat)] = []

    // DSP controls: FFT window size sits in the fixed area above the panels; the bass-management
    // high-pass params (floor/cutoff/Q) live in the scrollable LFE section.
    private let bassFloorField = NSTextField()
    private let bassFloorStepper = NSStepper()
    private let bassCutoffField = NSTextField()
    private let bassCutoffStepper = NSStepper()
    private let bassQField = NSTextField()
    private let bassQStepper = NSStepper()
    private let fftPopup = NSPopUpButton()
    private let fftNote = NSTextField(labelWithString: "")
    private var dspRows: [NSView] = []
    private let fftSizes = [1024, 2048, 4096]

    // Every group is edited in the SAME spherical terms (distance / azimuth / elevation), so the mono
    // centre + LFE behave exactly like the pairs; the pairs add spacing, everything has a gain.
    private let frontDistance_ = NSSlider()
    private let frontAzimuth_ = NSSlider()
    private let frontElevation_ = NSSlider()
    private let frontSpacing_ = NSSlider()
    private let frontGain_ = NSSlider()
    private let rearDistance_ = NSSlider()
    private let rearAzimuth_ = NSSlider()
    private let rearElevation_ = NSSlider()
    private let rearSpacing_ = NSSlider()
    private let rearGain_ = NSSlider()
    private let centerDistance_ = NSSlider()
    private let centerAzimuth_ = NSSlider()
    private let centerElevation_ = NSSlider()
    private let centerGain_ = NSSlider()
    private let lfeDistance_ = NSSlider()
    private let lfeAzimuth_ = NSSlider()
    private let lfeElevation_ = NSSlider()
    private let lfeGain_ = NSSlider()

    private let frontDistanceValue = NSTextField(labelWithString: "")
    private let frontAzimuthValue = NSTextField(labelWithString: "")
    private let frontElevationValue = NSTextField(labelWithString: "")
    private let frontSpacingValue = NSTextField(labelWithString: "")
    private let frontGainValue = NSTextField(labelWithString: "")
    private let rearDistanceValue = NSTextField(labelWithString: "")
    private let rearAzimuthValue = NSTextField(labelWithString: "")
    private let rearElevationValue = NSTextField(labelWithString: "")
    private let rearSpacingValue = NSTextField(labelWithString: "")
    private let rearGainValue = NSTextField(labelWithString: "")
    private let centerDistanceValue = NSTextField(labelWithString: "")
    private let centerAzimuthValue = NSTextField(labelWithString: "")
    private let centerElevationValue = NSTextField(labelWithString: "")
    private let centerGainValue = NSTextField(labelWithString: "")
    private let lfeDistanceValue = NSTextField(labelWithString: "")
    private let lfeAzimuthValue = NSTextField(labelWithString: "")
    private let lfeElevationValue = NSTextField(labelWithString: "")
    private let lfeGainValue = NSTextField(labelWithString: "")

    private let hint = NSTextField(wrappingLabelWithString:
        "Drag a marker on the stage to move it left/right and front/back, or use the per-group sliders "
        + "(distance, azimuth, elevation, plus spacing for the pairs and gain for all) — the stage and "
        + "the sliders stay in sync. Edits preview live on playback; leaving without Save reverts. Save "
        + "persists the layout + the Virtual 3D switch (the mode change applies when playback next starts).")

    override func loadView() {
        // Flipped so the manual frame layout runs top-down. Plain NSView (no Auto Layout) so the host can
        // size us freely (the preferences NSSplitView must not see a content-driven fittingSize to anchor).
        view = FlippedView(frame: NSRect(x: 0, y: 0, width: 520, height: 600))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        modeToggle.target = self
        modeToggle.action = #selector(onToggleMode)
        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(onReset)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r" // default button
        saveButton.target = self
        saveButton.action = #selector(onSave)
        stage.onChange = { [weak self] id, nx, ny in self?.onStageChange(id, nx, ny) }
        buildLayout()
        scene.setupScene()
        loadFromConfig()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        V3DConfig.clearPreview() // drop the live preview → engine reverts to the saved layout
    }

    override func viewDidLayout() { super.viewDidLayout(); relayout() }

    // MARK: - layout

    private func buildLayout() {
        // MANUAL frame layout — NO Auto Layout, NO NSStackView. Auto Layout on our view gives `view` a
        // content-driven fittingSize, and foobar's NSSplitView ANCHORS the list/content divider to it (so
        // the divider rebounds and the window won't even resize). The debug text-area page proved a plain
        // frame/autoresizing view has NO such anchor and tracks the pane perfectly. So here every control
        // is positioned by frame in relayout() (run from viewDidLayout) and resizes independently with the
        // pane — exactly like that text area. `view` is flipped (see loadView) so layout runs top-down.

        // Fixed regions live directly in `view`; the scrollable parameter list lives in `docView`.
        view.addSubview(modeToggle)
        stageLabel = makeCaption("Stage (top-down)")
        sceneLabel = makeCaption("Preview")
        view.addSubview(stageLabel)
        view.addSubview(sceneLabel)
        view.addSubview(stage)
        view.addSubview(scene)
        view.addSubview(resetButton)
        view.addSubview(saveButton)

        // Only the FFT window size stays fixed above the panels (it governs latency / output-buffer
        // sizing — a global concern). The bass-management high-pass params live in the scrollable LFE
        // section below.
        dspRows = [makeFftRow()]
        for r in dspRows { view.addSubview(r) }

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = docView
        view.addSubview(scrollView)

        // Build the scrollable form. Per group: direction (azimuth, elevation), distance, spacing (pairs
        // only), then gain last.
        addSection("Front pair")
        addRow("Azimuth", frontAzimuth_, frontAzimuthValue, -180, 180, #selector(onFrontAzimuth))
        addRow("Elevation", frontElevation_, frontElevationValue, -90, 90, #selector(onFrontElevation))
        addRow("Distance", frontDistance_, frontDistanceValue, 0.3, 4.0, #selector(onFrontDistance))
        addRow("Spacing", frontSpacing_, frontSpacingValue, 0, 180, #selector(onFrontSpacing))
        addRow("Gain (dB)", frontGain_, frontGainValue, -36, 24, #selector(onFrontGain))
        addSection("Rear pair")
        addRow("Azimuth", rearAzimuth_, rearAzimuthValue, 0, 360, #selector(onRearAzimuth))
        addRow("Elevation", rearElevation_, rearElevationValue, -90, 90, #selector(onRearElevation))
        addRow("Distance", rearDistance_, rearDistanceValue, 0.3, 4.0, #selector(onRearDistance))
        addRow("Spacing", rearSpacing_, rearSpacingValue, 0, 180, #selector(onRearSpacing))
        addRow("Gain (dB)", rearGain_, rearGainValue, -36, 24, #selector(onRearGain))
        addSection("Centre")
        addRow("Azimuth", centerAzimuth_, centerAzimuthValue, -180, 180, #selector(onCenterAzimuth))
        addRow("Elevation", centerElevation_, centerElevationValue, -90, 90, #selector(onCenterElevation))
        addRow("Distance", centerDistance_, centerDistanceValue, 0.3, 4.0, #selector(onCenterDistance))
        addRow("Gain (dB)", centerGain_, centerGainValue, -36, 24, #selector(onCenterGain))
        addSection("LFE")
        addRow("Azimuth", lfeAzimuth_, lfeAzimuthValue, -180, 180, #selector(onLfeAzimuth))
        addRow("Elevation", lfeElevation_, lfeElevationValue, -90, 90, #selector(onLfeElevation))
        addRow("Distance", lfeDistance_, lfeDistanceValue, 0.3, 4.0, #selector(onLfeDistance))
        addRow("Gain (dB)", lfeGain_, lfeGainValue, -36, 24, #selector(onLfeGain))
        // Bass-management high-pass (mains' low-end floor + crossover) — global DSP, grouped under LFE.
        addStepperRow("High-pass floor (dB)", bassFloorField, bassFloorStepper,
                      min: -36, max: 0, step: 1, decimals: 0,
                      #selector(onBassFloorStepper), #selector(onBassFloorField))
        addStepperRow("Crossover cutoff (Hz)", bassCutoffField, bassCutoffStepper,
                      min: 40, max: 300, step: 5, decimals: 0,
                      #selector(onBassCutoffStepper), #selector(onBassCutoffField))
        addStepperRow("Crossover Q (steepness)", bassQField, bassQStepper,
                      min: 0.3, max: 5, step: 0.1, decimals: 1,
                      #selector(onBassQStepper), #selector(onBassQField))
        view.addSubview(hint) // fixed (outside the scroll) — always visible
    }

    private func makeCaption(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    // A "number box with arrows": label (left) + editable numeric field + NSStepper (right). Field and
    // stepper are kept in sync by their actions; both pinned right via autoresizing so the label takes slack.
    private func makeStepperRow(_ title: String, _ field: NSTextField, _ stepper: NSStepper,
                                min: Double, max: Double, step: Double, decimals: Int,
                                _ stepperAction: Selector, _ fieldAction: Selector) -> NSView {
        let rowH: CGFloat = 24
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: rowH))
        row.autoresizesSubviews = true

        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 11)
        t.frame = NSRect(x: 0, y: 4, width: 190, height: 16)
        t.autoresizingMask = [.maxXMargin]

        stepper.minValue = min
        stepper.maxValue = max
        stepper.increment = step
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = stepperAction
        let sw: CGFloat = 19, fw: CGFloat = 64
        stepper.frame = NSRect(x: 360 - sw, y: 2, width: sw, height: 20)
        stepper.autoresizingMask = [.minXMargin]

        let fmt = NumberFormatter()
        fmt.minimumFractionDigits = decimals
        fmt.maximumFractionDigits = decimals
        field.formatter = fmt
        field.alignment = .right
        field.isEditable = true
        field.isBezeled = true
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.target = self
        field.action = fieldAction
        field.frame = NSRect(x: 360 - sw - 4 - fw, y: 3, width: fw, height: 18)
        field.autoresizingMask = [.minXMargin]

        row.addSubview(t)
        row.addSubview(field)
        row.addSubview(stepper)
        return row
    }

    private func makeFftRow() -> NSView {
        let rowH: CGFloat = 26
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: rowH))
        row.autoresizesSubviews = true

        let t = NSTextField(labelWithString: "FFT window")
        t.font = .systemFont(ofSize: 11)
        t.frame = NSRect(x: 0, y: 5, width: 90, height: 16)
        t.autoresizingMask = [.maxXMargin]

        fftPopup.removeAllItems()
        fftPopup.addItems(withTitles: fftSizes.map { String($0) })
        fftPopup.target = self
        fftPopup.action = #selector(onFftChanged)
        fftPopup.frame = NSRect(x: 92, y: 1, width: 78, height: 22)
        fftPopup.autoresizingMask = [.maxXMargin]

        fftNote.font = .systemFont(ofSize: 10)
        fftNote.textColor = .secondaryLabelColor
        fftNote.frame = NSRect(x: 178, y: 5, width: 360 - 178, height: 16)
        fftNote.autoresizingMask = [.width]

        row.addSubview(t)
        row.addSubview(fftPopup)
        row.addSubview(fftNote)
        return row
    }

    // The FFT block's algorithmic latency = N samples; show it in ms at 48 kHz so the user can size
    // foobar's output buffer accordingly (the buffer must cover at least this).
    private func updateFftNote() {
        let n = fftSizes[Swift.max(0, fftPopup.indexOfSelectedItem)]
        let ms = Double(n) / 48.0
        fftNote.stringValue = String(format: "≈ %.0f ms latency @ 48 kHz — set output buffer ≥ this", ms)
    }

    private func addSection(_ title: String) {
        let l = NSTextField(labelWithString: title)
        l.font = .boldSystemFont(ofSize: 13)
        l.textColor = .secondaryLabelColor
        docView.addSubview(l)
        formItems.append((l, 22))
    }

    private func addRow(_ title: String, _ slider: NSSlider, _ value: NSTextField,
                        _ mn: Double, _ mx: Double, _ action: Selector) {
        slider.minValue = mn
        slider.maxValue = mx
        slider.isContinuous = true
        slider.target = self
        slider.action = action
        // A plain (non-Auto-Layout) row: title pinned left, value pinned right, slider stretches between
        // them via autoresizing — so each row resizes independently when relayout() sets its width.
        let rowH: CGFloat = 24
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: rowH))
        row.autoresizesSubviews = true

        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 11)
        t.frame = NSRect(x: 0, y: 4, width: 104, height: 16)
        t.autoresizingMask = [.maxXMargin] // pinned left

        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.frame = NSRect(x: 360 - 60, y: 4, width: 58, height: 16)
        value.autoresizingMask = [.minXMargin] // pinned right

        slider.frame = NSRect(x: 110, y: 2, width: 360 - 110 - 64, height: 20)
        slider.autoresizingMask = [.width] // stretches between the labels

        row.addSubview(t)
        row.addSubview(slider)
        row.addSubview(value)
        docView.addSubview(row)
        formItems.append((row, rowH))
    }

    // Like addRow, but for a stepper row (number box + arrows) placed in the scrollable form.
    private func addStepperRow(_ title: String, _ field: NSTextField, _ stepper: NSStepper,
                               min: Double, max: Double, step: Double, decimals: Int,
                               _ stepperAction: Selector, _ fieldAction: Selector) {
        let row = makeStepperRow(title, field, stepper, min: min, max: max, step: step, decimals: decimals,
                                 stepperAction, fieldAction)
        docView.addSubview(row)
        formItems.append((row, row.frame.height))
    }

    // The single layout pass: position every control by frame from the current view bounds. No Auto
    // Layout, no fittingSize → foobar's NSSplitView has nothing to anchor to, so we track the pane.
    private func relayout() {
        guard isViewLoaded else { return }
        let W = view.bounds.width
        let H = view.bounds.height
        if W <= 1 || H <= 1 { return }
        let pad: CGFloat = 16
        let gap: CGFloat = 10
        let innerW = W - 2 * pad

        // The content column is a CENTRED block whose width is the two panels' span. The gap between the
        // panels widens a little with the window; each panel fills half the remaining width, clamped to
        // [320, 700] (shrinking below 320 only when the pane is too narrow to fit two). So the block grows
        // with the window up to ~1470 then stops, and the scroll list / header / buttons align to it.
        let panelGap = max(16, min(innerW * 0.06, 72))
        let fitSide = (innerW - panelGap) / 2
        let side = fitSide >= 320 ? min(fitSide, 700) : max(140, fitSide)
        let blockW = side * 2 + panelGap
        let bx = pad + max(0, (innerW - blockW) / 2) // left edge of the centred block

        // Header (mode toggle).
        var y: CGFloat = pad
        modeToggle.frame = NSRect(x: bx, y: y, width: blockW, height: 20)
        y += 20 + gap

        // DSP controls (bass high-pass + FFT), fixed above the panels.
        for r in dspRows {
            r.frame = NSRect(x: bx, y: y, width: blockW, height: r.frame.height)
            y += r.frame.height + 4
        }
        y += gap

        // Two 1:1 render panels at the top of the block.
        stageLabel.frame = NSRect(x: bx, y: y, width: side, height: 14)
        sceneLabel.frame = NSRect(x: bx + side + panelGap, y: y, width: side, height: 14)
        let py = y + 16
        stage.frame = NSRect(x: bx, y: py, width: side, height: side)
        scene.frame = NSRect(x: bx + side + panelGap, y: py, width: side, height: side)
        let topH = py + side + gap

        // Buttons at the block's bottom-right (aligned to the panels' right side).
        let bw: CGFloat = 84, bh: CGFloat = 26
        let buttonsY = H - pad - bh
        saveButton.frame = NSRect(x: bx + blockW - bw, y: buttonsY, width: bw, height: bh)
        resetButton.frame = NSRect(x: bx + blockW - 2 * bw - 8, y: buttonsY, width: bw, height: bh)

        // Hint text is FIXED (outside the scroll), just above the buttons, so it stays visible.
        hint.preferredMaxLayoutWidth = blockW
        let hintH = hint.intrinsicContentSize.height
        let hintY = buttonsY - gap - hintH
        hint.frame = NSRect(x: bx, y: hintY, width: blockW, height: hintH)

        // Scrollable parameter list fills between the panels and the hint, capped to the block width.
        let scrollH = max(0, hintY - gap - topH)
        scrollView.frame = NSRect(x: bx, y: topH, width: blockW, height: scrollH)

        // Lay the form out inside the (flipped) document, top to bottom.
        let docW = scrollView.contentView.bounds.width > 1 ? scrollView.contentView.bounds.width : blockW
        var dy: CGFloat = 0
        for (v, h) in formItems {
            v.frame = NSRect(x: 0, y: dy, width: docW, height: h)
            dy += h + 4
        }
        dy += 8
        docView.frame = NSRect(x: 0, y: 0, width: docW, height: max(dy, scrollH))
    }

    // MARK: - working layout -> UI

    // Full refresh: markers + sliders + toggle + derived preview. Used on load and reset.
    private func refreshAll() {
        modeToggle.state = v3dEnabled ? .on : .off
        let (fnx, fny) = pairMarker(az: frontAz, dist: frontDist)
        let (rnx, rny) = pairMarker(az: rearAz, dist: rearDist)
        stage.markers = [
            StageMarker(id: "front", nx: fnx, ny: fny, color: .systemBlue, label: "Front"),
            StageMarker(id: "rear", nx: rnx, ny: rny, color: .systemOrange, label: "Rear"),
            StageMarker(id: "center", nx: monoNx(centerX), ny: monoNy(centerZ), color: .systemGreen, label: "C"),
            StageMarker(id: "lfe", nx: monoNx(lfeX), ny: monoNy(lfeZ), color: .systemPurple, label: "LFE"),
        ]
        frontDistance_.doubleValue = frontDist
        frontAzimuth_.doubleValue = frontAz
        frontElevation_.doubleValue = frontEl
        frontSpacing_.doubleValue = frontSpacing
        frontGain_.doubleValue = frontGainDb
        rearDistance_.doubleValue = rearDist
        rearAzimuth_.doubleValue = rearAz
        rearElevation_.doubleValue = rearEl
        rearSpacing_.doubleValue = rearSpacing
        rearGain_.doubleValue = rearGainDb
        let cs = monoSph(centerX, centerY, centerZ)
        centerDistance_.doubleValue = cs.dist
        centerAzimuth_.doubleValue = cs.az
        centerElevation_.doubleValue = cs.el
        centerGain_.doubleValue = centerGainDb
        let ls = monoSph(lfeX, lfeY, lfeZ)
        lfeDistance_.doubleValue = ls.dist
        lfeAzimuth_.doubleValue = ls.az
        lfeElevation_.doubleValue = ls.el
        lfeGain_.doubleValue = lfeGainDb
        refreshDerived()
    }

    // Derived-only refresh: feedback dots + 3D preview + value readouts, AND push the working layout to
    // the engine as a live (unsaved) preview. The draggable markers and sliders are moved by the user's
    // gesture, so they are not reset here.
    private func refreshDerived() {
        let colors: [NSColor] = [.systemBlue, .systemBlue, .systemGreen, .systemPurple, .systemOrange, .systemOrange]
        let positions = speakerPositions()
        var dots: [(CGFloat, CGFloat, NSColor)] = []
        for (i, p) in positions.enumerated() where i < colors.count {
            dots.append((monoNx(p.0), monoNy(p.2), colors[i]))
        }
        stage.dots = dots
        scene.update(positions: positions)
        updateValueLabels()
        V3DConfig.previewLayoutValues(currentValues()) // live: engine renders this without persisting
    }

    private func updateValueLabels() {
        frontDistanceValue.stringValue = String(format: "%.1f m", frontDist)
        frontAzimuthValue.stringValue = String(format: "%.0f°", frontAz)
        frontElevationValue.stringValue = String(format: "%.0f°", frontEl)
        frontSpacingValue.stringValue = String(format: "%.0f°", frontSpacing)
        frontGainValue.stringValue = String(format: "%+.0f dB", frontGainDb)
        rearDistanceValue.stringValue = String(format: "%.1f m", rearDist)
        rearAzimuthValue.stringValue = String(format: "%.0f°", rearAz)
        rearElevationValue.stringValue = String(format: "%.0f°", rearEl)
        rearSpacingValue.stringValue = String(format: "%.0f°", rearSpacing)
        rearGainValue.stringValue = String(format: "%+.0f dB", rearGainDb)
        let cs = monoSph(centerX, centerY, centerZ)
        centerDistanceValue.stringValue = String(format: "%.1f m", cs.dist)
        centerAzimuthValue.stringValue = String(format: "%.0f°", cs.az)
        centerElevationValue.stringValue = String(format: "%.0f°", cs.el)
        centerGainValue.stringValue = String(format: "%+.0f dB", centerGainDb)
        let ls = monoSph(lfeX, lfeY, lfeZ)
        lfeDistanceValue.stringValue = String(format: "%.1f m", ls.dist)
        lfeAzimuthValue.stringValue = String(format: "%.0f°", ls.az)
        lfeElevationValue.stringValue = String(format: "%.0f°", ls.el)
        lfeGainValue.stringValue = String(format: "%+.0f dB", lfeGainDb)
    }

    // MARK: - mono spherical <-> cartesian
    // The mono speakers are stored as cartesian (x,y,z) in the layout, but edited in the same spherical
    // terms as the pairs. These convert between the two, matching speakerPositions()'s sph() convention
    // (azimuth 0 = front/−z, + = right/+x; elevation 0 = ear level, + = up).
    private func monoSph(_ x: Double, _ y: Double, _ z: Double) -> (dist: Double, az: Double, el: Double) {
        let d = (x * x + y * y + z * z).squareRoot()
        if d < 1e-6 { return (0, 0, 0) }
        let el = asin(Swift.max(-1, Swift.min(1, y / d))) * 180 / .pi
        let az = atan2(x, -z) * 180 / .pi
        return (d, az, el)
    }

    private func monoXYZ(dist: Double, az: Double, el: Double) -> (Double, Double, Double) {
        let a = az * .pi / 180, e = el * .pi / 180, ce = cos(e)
        return (dist * ce * sin(a), dist * sin(e), -dist * ce * cos(a))
    }

    // The six speaker positions [FL, FR, C, LFE, RL, RR] from the working layout — mirrors the C++
    // v3d_config::compute_speakers so the preview matches what the engine will render.
    private func speakerPositions() -> [(Double, Double, Double)] {
        func sph(_ azDeg: Double, _ elDeg: Double, _ d: Double) -> (Double, Double, Double) {
            let a = azDeg * .pi / 180, e = elDeg * .pi / 180, ce = cos(e)
            return (d * ce * sin(a), d * sin(e), -d * ce * cos(a))
        }
        let fl = sph(frontAz - frontSpacing / 2, frontEl, frontDist)
        let fr = sph(frontAz + frontSpacing / 2, frontEl, frontDist)
        let rl = sph(rearAz + rearSpacing / 2, rearEl, rearDist)
        let rr = sph(rearAz - rearSpacing / 2, rearEl, rearDist)
        return [fl, fr, (centerX, centerY, centerZ), (lfeX, lfeY, lfeZ), rl, rr]
    }

    // The 18-value layout array V3DConfig expects (geometry 0..13, gains 14..17).
    private func currentValues() -> [NSNumber] {
        [
            NSNumber(value: frontDist), NSNumber(value: frontSpacing), NSNumber(value: frontAz), NSNumber(value: frontEl),
            NSNumber(value: rearDist), NSNumber(value: rearSpacing), NSNumber(value: rearAz), NSNumber(value: rearEl),
            NSNumber(value: centerX), NSNumber(value: centerY), NSNumber(value: centerZ),
            NSNumber(value: lfeX), NSNumber(value: lfeY), NSNumber(value: lfeZ),
            NSNumber(value: frontGainDb), NSNumber(value: rearGainDb), NSNumber(value: centerGainDb), NSNumber(value: lfeGainDb),
        ]
    }

    // MARK: - normalized <-> metres mapping

    private func pairMarker(az: Double, dist: Double) -> (CGFloat, CGFloat) {
        let r = CGFloat(dist) / range
        let azRad = az * .pi / 180
        return (r * CGFloat(sin(azRad)), r * CGFloat(cos(azRad)))
    }

    private func azDist(_ nx: CGFloat, _ ny: CGFloat) -> (Double, Double) {
        let az = atan2(Double(nx), Double(ny)) * 180 / .pi
        let dist = Swift.min(Swift.max(hypot(Double(nx), Double(ny)) * Double(range), 0.3), Double(range))
        return (az, dist)
    }

    // The rear pair lives near ±180° (dead behind), exactly where atan2's −180/+180 seam is — so a small
    // drag there would flip the azimuth end to end. Express the rear in [0, 360) instead, which puts 180°
    // mid-range and the seam at the (rarely used for a rear speaker) front, so adjustment stays smooth.
    private func normRearAz(_ az: Double) -> Double {
        let a = az.truncatingRemainder(dividingBy: 360)
        return a < 0 ? a + 360 : a
    }

    private func monoNx(_ x: Double) -> CGFloat { CGFloat(x) / range }
    private func monoNy(_ z: Double) -> CGFloat { -CGFloat(z) / range } // front (-z) -> +y

    // MARK: - load / save

    private func loadFromConfig() {
        v3dEnabled = V3DConfig.virtual3DEnabled
        frontDist = V3DConfig.frontDistance; frontSpacing = V3DConfig.frontSpacing
        frontAz = V3DConfig.frontAzimuth; frontEl = V3DConfig.frontElevation
        rearDist = V3DConfig.rearDistance; rearSpacing = V3DConfig.rearSpacing
        rearAz = normRearAz(V3DConfig.rearAzimuth); rearEl = V3DConfig.rearElevation
        centerX = V3DConfig.centerX; centerY = V3DConfig.centerY; centerZ = V3DConfig.centerZ
        lfeX = V3DConfig.lfeX; lfeY = V3DConfig.lfeY; lfeZ = V3DConfig.lfeZ
        frontGainDb = V3DConfig.frontGainDb; rearGainDb = V3DConfig.rearGainDb
        centerGainDb = V3DConfig.centerGainDb; lfeGainDb = V3DConfig.lfeGainDb

        // DSP controls (bass high-pass + FFT window).
        bassFloorStepper.doubleValue = V3DConfig.bassFloorDb; bassFloorField.doubleValue = V3DConfig.bassFloorDb
        bassCutoffStepper.doubleValue = V3DConfig.bassCutoffHz; bassCutoffField.doubleValue = V3DConfig.bassCutoffHz
        bassQStepper.doubleValue = V3DConfig.bassQ; bassQField.doubleValue = V3DConfig.bassQ
        fftPopup.selectItem(at: fftSizes.firstIndex(of: V3DConfig.fftSize) ?? 1)
        updateFftNote()

        refreshAll()
    }

    @objc private func onSave() {
        V3DConfig.applyLayoutValues(currentValues(), mode: v3dEnabled) // persist + clear preview + set mode
    }

    @objc private func onReset() {
        let v = V3DConfig.standard51Values // canonical 5.1 from the C++ default (Save still needed to persist)
        guard v.count >= 18 else { return }
        frontDist = v[0].doubleValue; frontSpacing = v[1].doubleValue; frontAz = v[2].doubleValue; frontEl = v[3].doubleValue
        rearDist = v[4].doubleValue; rearSpacing = v[5].doubleValue; rearAz = normRearAz(v[6].doubleValue); rearEl = v[7].doubleValue
        centerX = v[8].doubleValue; centerY = v[9].doubleValue; centerZ = v[10].doubleValue
        lfeX = v[11].doubleValue; lfeY = v[12].doubleValue; lfeZ = v[13].doubleValue
        frontGainDb = v[14].doubleValue; rearGainDb = v[15].doubleValue
        centerGainDb = v[16].doubleValue; lfeGainDb = v[17].doubleValue
        refreshAll()
    }

    // MARK: - edits (working state + live preview; Save commits)

    @objc private func onToggleMode() { v3dEnabled = (modeToggle.state == .on) }

    // A drag moves the horizontal position (azimuth + distance); the sliders for the dragged group are
    // refreshed to match. Elevation/spacing aren't expressible on the 2D plane, so they're left as-is.
    private func onStageChange(_ id: String, _ nx: CGFloat, _ ny: CGFloat) {
        switch id {
        case "front":
            let (az, d) = azDist(nx, ny); frontAz = az; frontDist = d
            frontDistance_.doubleValue = frontDist
            frontAzimuth_.doubleValue = frontAz
        case "rear":
            let (az, d) = azDist(nx, ny); rearAz = normRearAz(az); rearDist = d
            rearDistance_.doubleValue = rearDist
            rearAzimuth_.doubleValue = rearAz
        case "center":
            centerX = Double(nx * range); centerZ = -Double(ny * range)
            let s = monoSph(centerX, centerY, centerZ)
            centerDistance_.doubleValue = s.dist; centerAzimuth_.doubleValue = s.az; centerElevation_.doubleValue = s.el
        case "lfe":
            lfeX = Double(nx * range); lfeZ = -Double(ny * range)
            let s = monoSph(lfeX, lfeY, lfeZ)
            lfeDistance_.doubleValue = s.dist; lfeAzimuth_.doubleValue = s.az; lfeElevation_.doubleValue = s.el
        default:
            break
        }
        refreshDerived()
    }

    // Move a marker to match its working position (slider -> stage), without firing onChange. Only the
    // distance/azimuth controls move a marker; elevation/spacing don't change the top-down position.
    private func syncPairMarkers() {
        let (fnx, fny) = pairMarker(az: frontAz, dist: frontDist)
        let (rnx, rny) = pairMarker(az: rearAz, dist: rearDist)
        stage.setMarker(id: "front", nx: fnx, ny: fny)
        stage.setMarker(id: "rear", nx: rnx, ny: rny)
    }

    private func syncMonoMarkers() {
        stage.setMarker(id: "center", nx: monoNx(centerX), ny: monoNy(centerZ))
        stage.setMarker(id: "lfe", nx: monoNx(lfeX), ny: monoNy(lfeZ))
    }

    // Front pair
    @objc private func onFrontDistance() { frontDist = frontDistance_.doubleValue; syncPairMarkers(); refreshDerived() }
    @objc private func onFrontAzimuth() { frontAz = frontAzimuth_.doubleValue; syncPairMarkers(); refreshDerived() }
    @objc private func onFrontElevation() { frontEl = frontElevation_.doubleValue; refreshDerived() }
    @objc private func onFrontSpacing() { frontSpacing = frontSpacing_.doubleValue; refreshDerived() }
    @objc private func onFrontGain() { frontGainDb = frontGain_.doubleValue; refreshDerived() }
    // Rear pair
    @objc private func onRearDistance() { rearDist = rearDistance_.doubleValue; syncPairMarkers(); refreshDerived() }
    @objc private func onRearAzimuth() { rearAz = rearAzimuth_.doubleValue; syncPairMarkers(); refreshDerived() }
    @objc private func onRearElevation() { rearEl = rearElevation_.doubleValue; refreshDerived() }
    @objc private func onRearSpacing() { rearSpacing = rearSpacing_.doubleValue; refreshDerived() }
    @objc private func onRearGain() { rearGainDb = rearGain_.doubleValue; refreshDerived() }
    // Centre (mono; stored cartesian, edited spherical)
    @objc private func onCenterDistance() { setCenter(dist: centerDistance_.doubleValue) }
    @objc private func onCenterAzimuth() { setCenter(az: centerAzimuth_.doubleValue) }
    @objc private func onCenterElevation() { setCenter(el: centerElevation_.doubleValue) }
    @objc private func onCenterGain() { centerGainDb = centerGain_.doubleValue; refreshDerived() }
    // LFE (mono; stored cartesian, edited spherical)
    @objc private func onLfeDistance() { setLfe(dist: lfeDistance_.doubleValue) }
    @objc private func onLfeAzimuth() { setLfe(az: lfeAzimuth_.doubleValue) }
    @objc private func onLfeElevation() { setLfe(el: lfeElevation_.doubleValue) }
    @objc private func onLfeGain() { lfeGainDb = lfeGain_.doubleValue; refreshDerived() }

    // DSP params — persisted immediately via V3DConfig (each write bumps the DSP generation so a playing
    // engine rebuilds the upmixer). Stepper and field mirror each other; setting the stepper clamps to range.
    @objc private func onBassFloorStepper() { bassFloorField.doubleValue = bassFloorStepper.doubleValue; V3DConfig.bassFloorDb = bassFloorStepper.doubleValue }
    @objc private func onBassFloorField() { bassFloorStepper.doubleValue = bassFloorField.doubleValue; bassFloorField.doubleValue = bassFloorStepper.doubleValue; V3DConfig.bassFloorDb = bassFloorStepper.doubleValue }
    @objc private func onBassCutoffStepper() { bassCutoffField.doubleValue = bassCutoffStepper.doubleValue; V3DConfig.bassCutoffHz = bassCutoffStepper.doubleValue }
    @objc private func onBassCutoffField() { bassCutoffStepper.doubleValue = bassCutoffField.doubleValue; bassCutoffField.doubleValue = bassCutoffStepper.doubleValue; V3DConfig.bassCutoffHz = bassCutoffStepper.doubleValue }
    @objc private func onBassQStepper() { bassQField.doubleValue = bassQStepper.doubleValue; V3DConfig.bassQ = bassQStepper.doubleValue }
    @objc private func onBassQField() { bassQStepper.doubleValue = bassQField.doubleValue; bassQField.doubleValue = bassQStepper.doubleValue; V3DConfig.bassQ = bassQStepper.doubleValue }
    @objc private func onFftChanged() { V3DConfig.fftSize = fftSizes[Swift.max(0, fftPopup.indexOfSelectedItem)]; updateFftNote() }

    // Replace one spherical component of a mono speaker (keeping the other two) and write back cartesian.
    private func setCenter(dist: Double? = nil, az: Double? = nil, el: Double? = nil) {
        let s = monoSph(centerX, centerY, centerZ)
        (centerX, centerY, centerZ) = monoXYZ(dist: dist ?? s.dist, az: az ?? s.az, el: el ?? s.el)
        syncMonoMarkers(); refreshDerived()
    }

    private func setLfe(dist: Double? = nil, az: Double? = nil, el: Double? = nil) {
        let s = monoSph(lfeX, lfeY, lfeZ)
        (lfeX, lfeY, lfeZ) = monoXYZ(dist: dist ?? s.dist, az: az ?? s.az, el: el ?? s.el)
        syncMonoMarkers(); refreshDerived()
    }
}

// Top-anchored document view for the scroll view: a flipped coordinate system makes the content lay
// out from the top down (AppKit's default origin is bottom-left, which would bottom-anchor the page).
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
