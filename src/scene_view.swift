//
//  scene_view.swift
//  foo_out_avfoundation
//
//  Read-only SceneKit preview of the virtual speaker rig: the listener at the origin and the six
//  virtual speakers (FL, FR, C, LFE, RL, RR) at the positions the engine actually renders (fed from
//  V3DConfig.speakerPositions — the same geometry). Orbit the camera to inspect; you place speakers
//  with the 2D stage + sliders, not by dragging here (true-3D dragging is ambiguous). Feedback only.
//

import SceneKit

final class SceneRigView: SCNView {

    // Speaker marker nodes in the fixed order [FL, FR, C, LFE, RL, RR].
    private var speakerNodes: [SCNNode] = []

    private static let speakerColors: [NSColor] = [
        .systemBlue,   // FL
        .systemBlue,   // FR
        .systemGreen,  // C
        .systemPurple, // LFE
        .systemOrange, // RL
        .systemOrange, // RR
    ]

    func setupScene() {
        let s = SCNScene()
        scene = s
        allowsCameraControl = true
        autoenablesDefaultLighting = true
        backgroundColor = .controlBackgroundColor

        // listener at the origin
        let listener = SCNNode(geometry: SCNSphere(radius: 0.18))
        listener.geometry?.firstMaterial?.diffuse.contents = NSColor.secondaryLabelColor
        s.rootNode.addChildNode(listener)

        // six speaker markers
        for color in SceneRigView.speakerColors {
            let node = SCNNode(geometry: SCNSphere(radius: 0.13))
            node.geometry?.firstMaterial?.diffuse.contents = color
            s.rootNode.addChildNode(node)
            speakerNodes.append(node)
        }

        // a faint ground grid plane for orientation
        let floor = SCNNode(geometry: SCNFloor())
        floor.geometry?.firstMaterial?.diffuse.contents = NSColor.gridColor
        floor.opacity = 0.15
        floor.position = SCNVector3(0, -1.5, 0)
        s.rootNode.addChildNode(floor)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.position = SCNVector3(0, 3, 6)
        camera.look(at: SCNVector3(0, 0, 0))
        s.rootNode.addChildNode(camera)
    }

    /// Move the speaker markers to the given positions (meters), order [FL, FR, C, LFE, RL, RR].
    func update(positions: [(Double, Double, Double)]) {
        for (i, node) in speakerNodes.enumerated() where i < positions.count {
            let p = positions[i]
            node.position = SCNVector3(CGFloat(p.0), CGFloat(p.1), CGFloat(p.2))
        }
    }
}
