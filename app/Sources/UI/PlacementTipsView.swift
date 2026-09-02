// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

/// The batter, drawn from the artwork in `Assets.xcassets/BatterOutline`.
///
/// The PNG is an alpha-only line drawing — every pixel is black with the ink in
/// the alpha channel — so `.renderingMode(.template)` tints the whole figure a
/// single colour and nothing of the original black survives. That is why it can
/// be shipped as-is rather than re-traced: the asset already *is* a mask.
///
/// It replaces a hand-traced `Shape`. The trace was close but not the drawing,
/// and "close but not it" is worse than either — the guide is meant to be
/// recognised at a glance over live video, not admired.
struct BatterOutline: View {
    /// Width ÷ height of the artwork (421 × 970 px), including the raised bat.
    /// Used to size the figure from the optics, so this must track the asset:
    /// re-crop the PNG and this number changes with it.
    static let aspect = 421.0 / 970.0

    var body: some View {
        Image("BatterOutline")
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}

/// The tripod diagram, drawn rather than photographed so it works at night
/// and in any locale: where to stand, how far, how high.
struct PlacementTipsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sectionLabel("From above — right", Theme.pass)
                    diagram
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))

                    // The failure this app was actually handed, drawn rather
                    // than described. Every number comes from the ball's path
                    // ACROSS the image, so a ball flying at the lens is
                    // foreshortened: it reads slow, and no amount of detector
                    // tuning recovers it. The right-hand picture is the only
                    // one that says which arrangements are wrong, and it is
                    // the one the framing outline can never draw, because the
                    // outline only ever sees the shot from the camera.
                    sectionLabel("From above — wrong", Theme.fail)
                    wrongDiagram
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))

                    sectionLabel("From the side", Theme.pass)
                    sideDiagram
                        .frame(height: 170)
                        .frame(maxWidth: .infinity)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))

                    tip("1", "Side-on to the flight, never behind",
                        "Square to the ball's flight, on the side the hitter FACES — first-base side for a right-hander, third-base side for a left-hander. Behind them their own body hides the bat at contact.")
                    tip("2", "Five to seven big steps",
                        "That's 4.5–6 m. Closer and the ball leaves the frame too fast; further and it gets too small to measure.")
                    tip("3", "Put the dashed line in the green band",
                        "That line is the real horizon — where level falls in the picture. Aim the phone until it sits inside the band and the phone is level, whatever the ground under the tripod is doing. If the line is off the bottom of the screen you are aiming up; off the top, you are aiming down. This is the check the batter outline cannot do for you: the outline can be matched perfectly from a phone lying in the grass, because moving back and tilting up fits a person into it just as well as standing it at belt height does.")
                    tip("4", "As high as the tripod goes — but keep it level",
                        "Belt height (about 1.1 m, where bat meets ball) is ideal. Once a hitter is stood in frame and the distance has been measured, the setup screen shows the height it has actually worked out — the outline alone can never tell, which is why it used to look right from the ground. A shorter tripod is fine: a level camera sitting low sees exactly the same geometry, just with the ball higher in the picture. What costs you accuracy is tilting the phone UP to point at contact height — so if it won't reach, leave it level and let the ball ride high in frame.")
                    tip("5", "Stand tall in the box until it chimes",
                        "The camera distance comes from the hitter. Type your height once in Settings, then stand in the box facing the phone with your knees straight and your weight even — the app measures the span from your nose to your ankles and works the distance out from that. It has to be a tall stance: a batting crouch shortens that span by about a tenth, and the app would read it as a camera a third of a metre further away, so it waits rather than measuring a crouch. Nothing you do afterwards matters, because the tripod has not moved. No hitter in frame? The \"…\" menu still has the ball, home plate, and a typed distance.")
                }
                .padding()
            }
            .background(Theme.black)
            .navigationTitle("Where the phone goes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.bold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Overhead view: hitter, ball flight, and the phone off to the side.
    private var diagram: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let hitter = CGPoint(x: w * 0.22, y: h * 0.5)
            let phone = CGPoint(x: w * 0.22, y: h * 0.88)

            var flight = Path()
            flight.move(to: hitter)
            flight.addLine(to: CGPoint(x: w * 0.95, y: h * 0.42))
            context.stroke(flight, with: .color(Theme.yellow),
                           style: StrokeStyle(lineWidth: 2, dash: [7, 5]))

            var sight = Path()
            sight.move(to: phone)
            sight.addLine(to: hitter)
            context.stroke(sight, with: .color(.white.opacity(0.45)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))

            context.fill(Path(ellipseIn: CGRect(x: hitter.x - 9, y: hitter.y - 9, width: 18, height: 18)),
                         with: .color(.white))
            context.fill(Path(ellipseIn: CGRect(x: hitter.x + 16, y: hitter.y - 5, width: 10, height: 10)),
                         with: .color(Theme.yellow))
            context.fill(Path(roundedRect: CGRect(x: phone.x - 7, y: phone.y - 12, width: 14, height: 24), cornerRadius: 3),
                         with: .color(Theme.yellow))

            context.draw(Text("HITTER").font(Theme.label(10)).foregroundStyle(.white),
                         at: CGPoint(x: hitter.x, y: hitter.y - 24))
            context.draw(Text("faces the phone").font(Theme.label(8)).foregroundStyle(.white.opacity(0.7)),
                         at: CGPoint(x: hitter.x + 4, y: hitter.y - 12))
            context.draw(Text("BALL FLIGHT").font(Theme.label(10)).foregroundStyle(Theme.yellow),
                         at: CGPoint(x: w * 0.7, y: h * 0.32))
            context.draw(Text("PHONE").font(Theme.label(10)).foregroundStyle(Theme.yellow),
                         at: CGPoint(x: phone.x + 52, y: phone.y))
            context.draw(Text("ABOUT 5 M").font(Theme.label(9)).foregroundStyle(.white.opacity(0.7)),
                         at: CGPoint(x: phone.x + 74, y: (phone.y + hitter.y) / 2))
        }
        .padding(10)
    }

    private func sectionLabel(_ text: String, _ colour: Color) -> some View {
        Text(text)
            .font(Theme.label(11)).tracking(1.3)
            .foregroundStyle(colour)
    }

    /// The two ways people actually get this wrong, side by side.
    ///
    /// Both are drawn from above with the same hitter in the same place, so
    /// the only thing that changes between this and the diagram above it is
    /// where the phone sits — which is the entire lesson.
    private var wrongDiagram: some View {
        Canvas { context, size in
            let w = size.width, h = size.height

            func cross(at p: CGPoint) {
                var x = Path()
                let a: CGFloat = 9
                x.move(to: CGPoint(x: p.x - a, y: p.y - a))
                x.addLine(to: CGPoint(x: p.x + a, y: p.y + a))
                x.move(to: CGPoint(x: p.x + a, y: p.y - a))
                x.addLine(to: CGPoint(x: p.x - a, y: p.y + a))
                context.stroke(x, with: .color(Theme.fail),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }

            // Left half: the phone downrange, ball flying into the lens.
            let hitterA = CGPoint(x: w * 0.10, y: h * 0.62)
            let phoneA = CGPoint(x: w * 0.40, y: h * 0.30)
            var flightA = Path()
            flightA.move(to: hitterA)
            flightA.addLine(to: CGPoint(x: phoneA.x - 6, y: phoneA.y + 10))
            context.stroke(flightA, with: .color(Theme.fail),
                           style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            context.fill(Path(ellipseIn: CGRect(x: hitterA.x - 8, y: hitterA.y - 8, width: 16, height: 16)),
                         with: .color(.white))
            context.fill(Path(roundedRect: CGRect(x: phoneA.x - 6, y: phoneA.y - 11, width: 12, height: 22), cornerRadius: 3),
                         with: .color(Theme.fail))
            cross(at: CGPoint(x: w * 0.25, y: h * 0.44))
            context.draw(Text("BALL FLIES AT THE LENS").font(Theme.label(9)).foregroundStyle(Theme.fail),
                         at: CGPoint(x: w * 0.25, y: h * 0.80))
            context.draw(Text("reads slow — flagged for depth")
                            .font(Theme.label(8)).foregroundStyle(.white.opacity(0.65)),
                         at: CGPoint(x: w * 0.25, y: h * 0.90))

            // Right half: the phone behind the hitter.
            let hitterB = CGPoint(x: w * 0.72, y: h * 0.50)
            let phoneB = CGPoint(x: w * 0.60, y: h * 0.50)
            var flightB = Path()
            flightB.move(to: hitterB)
            flightB.addLine(to: CGPoint(x: w * 0.97, y: h * 0.38))
            context.stroke(flightB, with: .color(Theme.fail),
                           style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            context.fill(Path(ellipseIn: CGRect(x: hitterB.x - 8, y: hitterB.y - 8, width: 16, height: 16)),
                         with: .color(.white))
            context.fill(Path(roundedRect: CGRect(x: phoneB.x - 6, y: phoneB.y - 11, width: 12, height: 22), cornerRadius: 3),
                         with: .color(Theme.fail))
            cross(at: CGPoint(x: w * 0.66, y: h * 0.30))
            context.draw(Text("PHONE BEHIND THE HITTER").font(Theme.label(9)).foregroundStyle(Theme.fail),
                         at: CGPoint(x: w * 0.74, y: h * 0.80))
            context.draw(Text("their body hides the bat")
                            .font(Theme.label(8)).foregroundStyle(.white.opacity(0.65)),
                         at: CGPoint(x: w * 0.74, y: h * 0.90))
        }
        .padding(10)
    }

    /// Side elevation: the height question, which no overhead view can show
    /// and which the framing outline silently assumes an answer to.
    private var sideDiagram: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let ground = h * 0.80

            var g = Path()
            g.move(to: CGPoint(x: 0, y: ground))
            g.addLine(to: CGPoint(x: w, y: ground))
            context.stroke(g, with: .color(.white.opacity(0.3)), lineWidth: 1.5)

            // Hitter and contact point.
            let hx = w * 0.22
            var body = Path()
            body.move(to: CGPoint(x: hx, y: ground))
            body.addLine(to: CGPoint(x: hx, y: ground - h * 0.44))
            context.stroke(body, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: hx - 6, y: ground - h * 0.54, width: 12, height: 12)),
                         with: .color(.white))
            let contactY = ground - h * 0.28
            context.fill(Path(ellipseIn: CGRect(x: hx + 16, y: contactY - 5, width: 10, height: 10)),
                         with: .color(Theme.yellow))

            // The right camera: level, at contact height.
            let cx = w * 0.74
            var tripod = Path()
            tripod.move(to: CGPoint(x: cx, y: contactY))
            tripod.addLine(to: CGPoint(x: cx, y: ground))
            context.stroke(tripod, with: .color(Theme.steel),
                           style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            context.fill(Path(roundedRect: CGRect(x: cx - 9, y: contactY - 7, width: 18, height: 14), cornerRadius: 3),
                         with: .color(Theme.pass))
            var sight = Path()
            sight.move(to: CGPoint(x: cx - 10, y: contactY))
            sight.addLine(to: CGPoint(x: hx + 26, y: contactY))
            context.stroke(sight, with: .color(Theme.pass.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            context.draw(Text("LEVEL, 1.1 M").font(Theme.label(9)).foregroundStyle(Theme.pass),
                         at: CGPoint(x: cx + 4, y: contactY - 20))

            // The wrong one: on the ground, aimed up to compensate.
            var badSight = Path()
            badSight.move(to: CGPoint(x: w * 0.90, y: ground - 6))
            badSight.addLine(to: CGPoint(x: hx + 30, y: contactY - h * 0.10))
            context.stroke(badSight, with: .color(Theme.fail.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            context.fill(Path(roundedRect: CGRect(x: w * 0.90 - 9, y: ground - 13, width: 18, height: 14), cornerRadius: 3),
                         with: .color(Theme.fail))
            context.draw(Text("ON THE GROUND, AIMED UP").font(Theme.label(9)).foregroundStyle(Theme.fail),
                         at: CGPoint(x: w * 0.72, y: ground + 16))
            context.draw(Text("the outline still matches — that is the trap")
                            .font(Theme.label(8)).foregroundStyle(.white.opacity(0.65)),
                         at: CGPoint(x: w * 0.5, y: ground + 30))
        }
        .padding(10)
    }

    private func tip(_ n: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n)
                .font(Theme.numeral(18))
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(Theme.yellow, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .heavy))
                Text(body).font(.system(size: 13)).foregroundStyle(Theme.steel)
            }
        }
    }
}
