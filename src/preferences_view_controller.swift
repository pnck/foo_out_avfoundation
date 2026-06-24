//
//  preferences_view_controller.swift
//  foo_out_avfoundation
//
//  The component's preferences page for the virtual speaker rig. A mode switch, a top-down stage where
//  you drag the front pair, rear pair, mono centre and LFE around the listener, sliders for the
//  per-pair spacing/elevation and the mono speakers' height, and a live SceneKit preview of the rig.
//
//  Edits are DEFERRED: they update the on-screen working layout + preview only. Nothing reaches the
//  engine or configStore until "Save" is pressed (which commits the whole layout + the V3D switch in
//  one shot). "Reset" loads the standard 5.1 layout into the editor (still needs Save to apply).
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

    private let modeToggle = NSButton(checkboxWithTitle: "Enable Virtual 3D (custom speaker rig)",
                                      target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let stage = StageView()
    private let scene = SceneRigView()

    private let frontSpacing_ = NSSlider()
    private let frontElevation_ = NSSlider()
    private let rearSpacing_ = NSSlider()
    private let rearElevation_ = NSSlider()
    private let centerHeight_ = NSSlider()
    private let lfeHeight_ = NSSlider()

    private let frontSpacingValue = NSTextField(labelWithString: "")
    private let frontElevationValue = NSTextField(labelWithString: "")
    private let rearSpacingValue = NSTextField(labelWithString: "")
    private let rearElevationValue = NSTextField(labelWithString: "")
    private let centerHeightValue = NSTextField(labelWithString: "")
    private let lfeHeightValue = NSTextField(labelWithString: "")

    private let hint = NSTextField(wrappingLabelWithString:
        "Drag the front/rear pair centres and the mono centre/LFE around the listener (top-down). "
        + "Spacing/elevation are per-pair sliders; the mono speakers have a height slider. "
        + "Nothing is applied until you press Save (this includes the Virtual 3D switch); the mode "
        + "change takes effect when playback next starts. Reset loads the standard 5.1 layout.")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 540))
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

    // MARK: - layout

    private func buildLayout() {
        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.heightAnchor.constraint(equalToConstant: 240).isActive = true
        stage.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        scene.translatesAutoresizingMaskIntoConstraints = false
        scene.heightAnchor.constraint(equalToConstant: 240).isActive = true
        scene.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let topRow = NSStackView(views: [labeled("Stage (top-down)", stage),
                                         labeled("Preview", scene)])
        topRow.orientation = .horizontal
        topRow.distribution = .fillEqually
        topRow.spacing = 12

        let controls = NSStackView(views: [
            section("Front pair"),
            sliderRow("Spacing", frontSpacing_, frontSpacingValue, min: 0, max: 180, action: #selector(onFrontSpacing)),
            sliderRow("Elevation", frontElevation_, frontElevationValue, min: -60, max: 60, action: #selector(onFrontElevation)),
            section("Rear pair"),
            sliderRow("Spacing", rearSpacing_, rearSpacingValue, min: 0, max: 180, action: #selector(onRearSpacing)),
            sliderRow("Elevation", rearElevation_, rearElevationValue, min: -60, max: 60, action: #selector(onRearElevation)),
            section("Mono speakers"),
            sliderRow("Centre height", centerHeight_, centerHeightValue, min: -2, max: 2, action: #selector(onCenterHeight)),
            sliderRow("LFE height", lfeHeight_, lfeHeightValue, min: -2, max: 2, action: #selector(onLfeHeight)),
        ])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 6

        let buttons = NSStackView(views: [resetButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let header = NSStackView(views: [modeToggle])
        header.orientation = .horizontal

        let root = NSStackView(views: [header, topRow, controls, buttons, hint])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])
    }

    private func labeled(_ title: String, _ content: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let box = NSStackView(views: [label, content])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 4
        return box
    }

    private func section(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func sliderRow(_ title: String, _ slider: NSSlider, _ valueLabel: NSTextField,
                           min: Double, max: Double, action: Selector) -> NSView {
        slider.minValue = min
        slider.maxValue = max
        slider.isContinuous = true
        slider.target = self
        slider.action = action
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: 96).isActive = true

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(equalToConstant: 56).isActive = true

        let row = NSStackView(views: [titleLabel, slider, valueLabel])
        row.orientation = .horizontal
        row.spacing = 8
        return row
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
        frontSpacing_.doubleValue = frontSpacing
        frontElevation_.doubleValue = frontEl
        rearSpacing_.doubleValue = rearSpacing
        rearElevation_.doubleValue = rearEl
        centerHeight_.doubleValue = centerY
        lfeHeight_.doubleValue = lfeY
        refreshDerived()
    }

    // Derived-only refresh: feedback dots + 3D preview + value readouts (the draggable markers and
    // sliders are moved by the user's gesture, so they are not reset here).
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
    }

    private func updateValueLabels() {
        frontSpacingValue.stringValue = String(format: "%.0f°", frontSpacing)
        frontElevationValue.stringValue = String(format: "%.0f°", frontEl)
        rearSpacingValue.stringValue = String(format: "%.0f°", rearSpacing)
        rearElevationValue.stringValue = String(format: "%.0f°", rearEl)
        centerHeightValue.stringValue = String(format: "%.1f m", centerY)
        lfeHeightValue.stringValue = String(format: "%.1f m", lfeY)
    }

    // The six speaker positions [FL, FR, C, LFE, RL, RR] from the working layout — mirrors the C++
    // v3d_config::compute_speakers so the preview matches what the engine will render after Save.
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

    private func monoNx(_ x: Double) -> CGFloat { CGFloat(x) / range }
    private func monoNy(_ z: Double) -> CGFloat { -CGFloat(z) / range } // front (-z) -> +y

    // MARK: - load / save

    private func loadFromConfig() {
        v3dEnabled = V3DConfig.virtual3DEnabled
        frontDist = V3DConfig.frontDistance; frontSpacing = V3DConfig.frontSpacing
        frontAz = V3DConfig.frontAzimuth; frontEl = V3DConfig.frontElevation
        rearDist = V3DConfig.rearDistance; rearSpacing = V3DConfig.rearSpacing
        rearAz = V3DConfig.rearAzimuth; rearEl = V3DConfig.rearElevation
        centerX = V3DConfig.centerX; centerY = V3DConfig.centerY; centerZ = V3DConfig.centerZ
        lfeX = V3DConfig.lfeX; lfeY = V3DConfig.lfeY; lfeZ = V3DConfig.lfeZ
        refreshAll()
    }

    @objc private func onSave() {
        let values: [NSNumber] = [
            NSNumber(value: frontDist), NSNumber(value: frontSpacing), NSNumber(value: frontAz), NSNumber(value: frontEl),
            NSNumber(value: rearDist), NSNumber(value: rearSpacing), NSNumber(value: rearAz), NSNumber(value: rearEl),
            NSNumber(value: centerX), NSNumber(value: centerY), NSNumber(value: centerZ),
            NSNumber(value: lfeX), NSNumber(value: lfeY), NSNumber(value: lfeZ),
        ]
        V3DConfig.applyLayoutValues(values, mode: v3dEnabled)
    }

    @objc private func onReset() {
        let v = V3DConfig.standard51Values // canonical 5.1 from the C++ default (Save still needed to apply)
        guard v.count >= 14 else { return }
        frontDist = v[0].doubleValue; frontSpacing = v[1].doubleValue; frontAz = v[2].doubleValue; frontEl = v[3].doubleValue
        rearDist = v[4].doubleValue; rearSpacing = v[5].doubleValue; rearAz = v[6].doubleValue; rearEl = v[7].doubleValue
        centerX = v[8].doubleValue; centerY = v[9].doubleValue; centerZ = v[10].doubleValue
        lfeX = v[11].doubleValue; lfeY = v[12].doubleValue; lfeZ = v[13].doubleValue
        refreshAll()
    }

    // MARK: - edits (working state only; Save commits)

    @objc private func onToggleMode() { v3dEnabled = (modeToggle.state == .on) }

    private func onStageChange(_ id: String, _ nx: CGFloat, _ ny: CGFloat) {
        switch id {
        case "front":
            let (az, d) = azDist(nx, ny); frontAz = az; frontDist = d
        case "rear":
            let (az, d) = azDist(nx, ny); rearAz = az; rearDist = d
        case "center":
            centerX = Double(nx * range); centerZ = -Double(ny * range)
        case "lfe":
            lfeX = Double(nx * range); lfeZ = -Double(ny * range)
        default:
            break
        }
        refreshDerived()
    }

    @objc private func onFrontSpacing() { frontSpacing = frontSpacing_.doubleValue; refreshDerived() }
    @objc private func onFrontElevation() { frontEl = frontElevation_.doubleValue; refreshDerived() }
    @objc private func onRearSpacing() { rearSpacing = rearSpacing_.doubleValue; refreshDerived() }
    @objc private func onRearElevation() { rearEl = rearElevation_.doubleValue; refreshDerived() }
    @objc private func onCenterHeight() { centerY = centerHeight_.doubleValue; refreshDerived() }
    @objc private func onLfeHeight() { lfeY = lfeHeight_.doubleValue; refreshDerived() }
}
