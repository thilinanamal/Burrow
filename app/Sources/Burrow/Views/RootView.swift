import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: model.tab.background, startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.45), value: model.tab)

            VStack(spacing: 0) {
                TopBar()
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                Group {
                    switch model.tab {
                    case .clean: CleanView(model: model.clean)
                    case .apps: AppsView(model: model.apps)
                    case .optimize: OptimizeView(model: model.optimize)
                    case .analyze: AnalyzeView(model: model.analyze)
                    case .status: StatusView(model: model.status)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }

            if model.cliMissing {
                Text("The bundled Mole CLI was not found. Reinstall Burrow.")
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.dangerRed.opacity(0.85)))
                    .padding(.top, 80)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
}

struct TopBar: View {
    @EnvironmentObject var model: AppModel
    @Namespace private var pill

    var body: some View {
        ZStack {
            HStack(spacing: 4) {
                BurrowLogo()
                    .frame(width: 34, height: 34)
                    .padding(.trailing, 6)
                ForEach(AppTab.allCases) { tab in
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.tab = tab }
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(model.tab == tab ? Color.black : Color.white.opacity(0.72))
                            .padding(.horizontal, 22)
                            .frame(height: 36)
                            .background {
                                if model.tab == tab {
                                    Capsule().fill(Color.white).matchedGeometryEffect(id: "pill", in: pill)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(5)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))

            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(Color.goodGreen).frame(width: 6, height: 6)
                    Text(model.cliVersion.map { "Mole CLI \($0)" } ?? "Mole CLI")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(Capsule().fill(Color.goodGreen.opacity(0.14)))
                .overlay(Capsule().strokeBorder(Color.goodGreen.opacity(0.3)))
                .help("Every action runs the open-source Mole CLI bundled inside this app.")
            }
            .padding(.trailing, 20)
        }
        .frame(height: 48)
    }
}

/// Burrow's own mark: a hill with a tunnel entrance.
struct BurrowLogo: View {
    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(ellipseIn: rect), with: .color(Color(hex: 0xF3EEE6)))
            var hill = Path()
            hill.move(to: CGPoint(x: size.width * 0.12, y: size.height * 0.72))
            hill.addQuadCurve(to: CGPoint(x: size.width * 0.88, y: size.height * 0.72),
                              control: CGPoint(x: size.width * 0.5, y: size.height * 0.08))
            hill.closeSubpath()
            ctx.fill(hill, with: .color(Color(hex: 0x6B4A33)))
            let hole = CGRect(x: size.width * 0.36, y: size.height * 0.47,
                              width: size.width * 0.28, height: size.height * 0.25)
            var arch = Path()
            arch.move(to: CGPoint(x: hole.minX, y: hole.maxY))
            arch.addArc(center: CGPoint(x: hole.midX, y: hole.minY + hole.width / 2),
                        radius: hole.width / 2, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            arch.addLine(to: CGPoint(x: hole.maxX, y: hole.maxY))
            arch.closeSubpath()
            ctx.fill(arch, with: .color(Color(hex: 0x1E1612)))
            ctx.fill(Path(CGRect(x: size.width * 0.1, y: size.height * 0.71,
                                 width: size.width * 0.8, height: size.height * 0.05)),
                     with: .color(Color(hex: 0x4E8A4F)))
        }
        .clipShape(Circle())
    }
}
