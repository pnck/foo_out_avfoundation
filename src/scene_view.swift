//
//  scene_view.swift
//  foo_out_avfoundation
//
//  Read-only SceneKit visualization of the virtual field: a listener at the origin and a source
//  marker the 2D pads drive. Orbit the camera to inspect; you do NOT place the source here (dragging
//  in true 3D is ambiguous — that's what the 2D pads are for). Purely a feedback view.
//

import SceneKit

final class Scene3DView: SCNView {

    private let sourceNode = SCNNode()

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

        // source marker
        sourceNode.geometry = SCNSphere(radius: 0.14)
        sourceNode.geometry?.firstMaterial?.diffuse.contents = NSColor.controlAccentColor
        s.rootNode.addChildNode(sourceNode)

        // a faint ground grid plane for orientation
        let floor = SCNNode(geometry: SCNFloor())
        floor.geometry?.firstMaterial?.diffuse.contents = NSColor.gridColor
        floor.opacity = 0.15
        floor.position = SCNVector3(0, -1.5, 0)
        s.rootNode.addChildNode(floor)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.position = SCNVector3(0, 2.5, 6)
        camera.look(at: SCNVector3(0, 0, 0))
        s.rootNode.addChildNode(camera)
    }

    /// Move the source marker (metres; listener at origin, -z is in front).
    func updateSource(x: Double, y: Double, z: Double) {
        sourceNode.position = SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z))
    }
}
