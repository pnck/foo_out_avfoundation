//
//  preferences_view_controller.swift
//  foo_out_avfoundation
//
//  The component's preferences page: a mode switch plus the DAW-style 3D panner (top-down pad +
//  elevation pad) and a read-only SceneKit preview. Instantiated by preferences_page.mm via
//  fb2k::wrapNSObject. Writes persist immediately through V3DConfig (configStore); a mode change
//  takes effect on the next playback start (the output rebuilds its engine then).
//
//  @objc name is fixed so the ObjC++ side can reference it through the generated -Swift.h header.
//

import AppKit

@objc(V3DPreferencesViewController)
final class V3DPreferencesViewController: NSViewController {

    // Half-extent of the virtual field the pads map onto, in metres (puck edge = ±RANGE).
    private let range: CGFloat = 5.0

    private let modeToggle = NSButton(checkboxWithTitle: "Enable Virtual 3D (custom positioning)",
                                      target: nil, action: nil)
    private let topDown = PannerPadView()
    private let elevation = PannerPadView()
    private let scene = Scene3DView()
    private let hint = NSTextField(wrappingLabelWithString:
        "Drag the top-down pad for left/right + front/back, the elevation pad for up/down. "
        + "A mode change applies when playback next starts.")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 380))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        scene.setupScene()

        modeToggle.target = self
        modeToggle.action = #selector(onToggleMode)
        topDown.onChange = { [weak self] x, y in self?.onTopDown(x, y) }
        elevation.onChange = { [weak self] x, y in self?.onElevation(x, y) }

        loadFromConfig()
    }

    private func buildLayout() {
        let padsRow = NSStackView(views: [labeled("Top-down (L/R · front/back)", topDown),
                                          labeled("Elevation (L/R · up/down)", elevation)])
        padsRow.orientation = .horizontal
        padsRow.distribution = .fillEqually
        padsRow.spacing = 12

        for pad in [topDown, elevation] {
            pad.translatesAutoresizingMaskIntoConstraints = false
            pad.heightAnchor.constraint(equalToConstant: 150).isActive = true
            pad.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        }
        scene.translatesAutoresizingMaskIntoConstraints = false
        scene.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let root = NSStackView(views: [modeToggle, padsRow, scene, hint])
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

    // MARK: - config <-> UI

    private func loadFromConfig() {
        modeToggle.state = V3DConfig.virtual3DEnabled ? .on : .off
        let (x, y, z) = (V3DConfig.sourceX, V3DConfig.sourceY, V3DConfig.sourceZ)
        topDown.valueX = clampNorm(x); topDown.valueY = clampNorm(-z) // front (-z) -> top (+y)
        elevation.valueX = clampNorm(x); elevation.valueY = clampNorm(y)
        scene.updateSource(x: x, y: y, z: z)
    }

    private func clampNorm(_ metres: Double) -> CGFloat {
        max(-1, min(1, CGFloat(metres) / range))
    }

    @objc private func onToggleMode() {
        V3DConfig.virtual3DEnabled = (modeToggle.state == .on)
    }

    private func onTopDown(_ x: CGFloat, _ y: CGFloat) {
        V3DConfig.sourceX = Double(x * range)
        V3DConfig.sourceZ = Double(-y * range)
        elevation.valueX = x // keep the shared L/R axis in sync
        scene.updateSource(x: V3DConfig.sourceX, y: V3DConfig.sourceY, z: V3DConfig.sourceZ)
    }

    private func onElevation(_ x: CGFloat, _ y: CGFloat) {
        V3DConfig.sourceX = Double(x * range)
        V3DConfig.sourceY = Double(y * range)
        topDown.valueX = x
        scene.updateSource(x: V3DConfig.sourceX, y: V3DConfig.sourceY, z: V3DConfig.sourceZ)
    }
}
