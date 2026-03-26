import SwiftUI

struct ClusterGraphView: View {
    let nodes: [ClusterNode]
    let bandwidth: [BandwidthSnapshot]
    let positions: [String: CGPoint]
    var onNodeTap: ((ClusterNode) -> Void)?

    @State private var animationPhase: CGFloat = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let scale = min(size.width / 400, size.height / 400)
                let offset = CGPoint(
                    x: (size.width - 400 * scale) / 2,
                    y: (size.height - 400 * scale) / 2
                )

                func scaled(_ point: CGPoint) -> CGPoint {
                    CGPoint(x: point.x * scale + offset.x, y: point.y * scale + offset.y)
                }

                let localNode = nodes.first(where: \.isLocal)

                // Draw connection lines
                if let localPos = localNode.flatMap({ positions[$0.id] }) {
                    for node in nodes where !node.isLocal {
                        guard let pos = positions[node.id] else { continue }
                        let from = scaled(localPos)
                        let to = scaled(pos)

                        let bw = bandwidth.first { $0.nodeId == node.id }
                        let lineWidth = max(1, min(8, (bw?.ewmaTokPerSec ?? 0) / 15))

                        var path = Path()
                        path.move(to: from)
                        path.addLine(to: to)

                        // Animated dashed line
                        let phase = animationPhase * 20
                        context.stroke(
                            path,
                            with: .color(.gray.opacity(0.3)),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        context.stroke(
                            path,
                            with: .color(ColorTheme.nodeColor(load: node.load, healthy: node.isHealthy).opacity(0.6)),
                            style: StrokeStyle(
                                lineWidth: lineWidth,
                                lineCap: .round,
                                dash: [8, 8],
                                dashPhase: phase
                            )
                        )

                        // Bandwidth label at midpoint
                        if let bw {
                            let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 - 12)
                            let text = Text(Formatters.tokPerSec(bw.ewmaTokPerSec))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                            context.draw(context.resolve(text), at: mid)
                        }
                    }
                }

                // Draw nodes
                for node in nodes {
                    guard let pos = positions[node.id] else { continue }
                    let center = scaled(pos)
                    let radius = CGFloat(max(20, min(40, node.slots * 5))) * scale
                    let color = ColorTheme.nodeColor(load: node.load, healthy: node.isHealthy)

                    // Node circle
                    let circle = Path(ellipseIn: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    ))
                    context.fill(circle, with: .color(color.opacity(0.3)))
                    context.stroke(circle, with: .color(color), style: StrokeStyle(lineWidth: 2))

                    // Local node indicator
                    if node.isLocal {
                        let innerCircle = Path(ellipseIn: CGRect(
                            x: center.x - radius * 0.4,
                            y: center.y - radius * 0.4,
                            width: radius * 0.8,
                            height: radius * 0.8
                        ))
                        context.fill(innerCircle, with: .color(color.opacity(0.6)))
                    }

                    // Label
                    let label = Text(node.isLocal ? "Local" : "\(node.host)")
                        .font(.system(size: 10 * scale, weight: .semibold))
                    context.draw(context.resolve(label), at: CGPoint(x: center.x, y: center.y + radius + 14 * scale))

                    let portLabel = Text(":\(node.port)")
                        .font(.system(size: 8 * scale, design: .monospaced))
                        .foregroundStyle(.secondary)
                    context.draw(context.resolve(portLabel), at: CGPoint(x: center.x, y: center.y + radius + 26 * scale))
                }
            }
            .onChange(of: timeline.date) { _, _ in
                animationPhase += 0.016
                if animationPhase > 100 { animationPhase = 0 }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary)
        )
        .padding()
        .onTapGesture { location in
            // Hit test nodes
            guard let tapped = hitTest(location: location) else { return }
            onNodeTap?(tapped)
        }
    }

    private func hitTest(location: CGPoint) -> ClusterNode? {
        for node in nodes {
            guard let pos = positions[node.id] else { continue }
            let dx = location.x - pos.x
            let dy = location.y - pos.y
            if dx * dx + dy * dy < 900 { // 30pt radius
                return node
            }
        }
        return nil
    }
}
