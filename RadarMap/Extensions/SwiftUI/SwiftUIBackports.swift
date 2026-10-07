//
//  SwiftUIBackports.swift
//  RadarMap
//
//  Created by Firdavs Khaydarov on 19/07/2026.
//  Copyright © 2026 RadarMap. All rights reserved.
//

import SwiftUI
import ImagePlayground
#if canImport(WidgetKit)
import WidgetKit
#endif

struct Backport<Content> {
    let content: Content

    init(_ content: Content) {
        self.content = content
    }
}

extension View {
    var backport: Backport<Self> { Backport(self) }
}

extension ToolbarContent {
    var backport: Backport<Self> { Backport(self) }
}

// MARK: iOS 26 Extensions

enum BackportGlass: Equatable, Sendable {
    case regular
    case clear
    case identity
    case tinted(Color?)
    case interactive(isEnabled: Bool)
    case tintedAndInteractive(color: Color?, isEnabled: Bool)

    // Default convenience
    static var regularInteractive: BackportGlass {
        .tintedAndInteractive(color: nil, isEnabled: true)
    }
}

@available(iOS 26, macOS 26, *)
extension BackportGlass {
    var toGlass: Glass {
        switch self {
        case .regular:
            return .regular
        case .clear:
            return .clear
        case .identity:
            return .identity
        case .tinted(let color):
            return .regular.tint(color)
        case .interactive(let isEnabled):
            return .regular.interactive(isEnabled)
        case .tintedAndInteractive(let color, let isEnabled):
            return .regular.tint(color).interactive(isEnabled)
        }
    }
}

enum BackportGlassEffectTransition: Equatable, Sendable {
    case identity
    case materialize
}

@available(iOS 26, macOS 26, *)
extension BackportGlassEffectTransition {
    var toTransition: GlassEffectTransition {
        switch self {
        case .identity:
            return .identity
        case .materialize:
            return .materialize
        }
    }
}

enum BackportScrollEdgeEffectStyle: Hashable, Sendable {
    case automatic
    case hard
    case soft
}

@available(iOS 26.0, macOS 26, *)
extension BackportScrollEdgeEffectStyle {
    var toStyle: ScrollEdgeEffectStyle {
        switch self {
        case .automatic: return .automatic
        case .hard: return .hard
        case .soft: return .soft
        }
    }
}

@available(iOS 26.0, macOS 26, *)
extension BackportSymbolColorRenderingMode {
    var toMode: SymbolColorRenderingMode {
        switch self {
        case .flat: return .flat
        case .gradient: return .gradient
        }
    }
}

enum BackportSymbolColorRenderingMode: Equatable, Sendable {
    case flat
    case gradient
}

enum BackportSymbolVariableValueMode: Equatable, Sendable {
    case color
    case draw
}

@available(iOS 26.0, macOS 26, *)
extension BackportSymbolVariableValueMode {
    var toMode: SymbolVariableValueMode {
        switch self {
        case .color: return .color
        case .draw: return .draw
        }
    }
}

enum BackportTabBarMinimizeBehavior: Hashable, Sendable {
    case automatic
    case onScrollDown
    case onScrollUp
    case never
}

enum BackportSearchToolbarBehavior: Hashable, Sendable {
    case automatic
    case minimize
}

@available(iOS 26.0, macOS 26, *)
extension BackportTabBarMinimizeBehavior {
    var toBehavior: TabBarMinimizeBehavior {
        switch self {
        case .automatic:
            return .automatic
#if os(iOS)
        case .onScrollDown:
            return .onScrollDown
        case .onScrollUp:
            return .onScrollUp
        case .never:
            return .never
#else
        default:
            return .automatic
#endif
        }
    }
}


@MainActor
@available(iOS 14, macOS 12, *)
extension Backport where Content: View {
    @ViewBuilder func presentationBackground(in shape: some ShapeStyle = Material.thin) -> some View {
        if #available(iOS 26.0, macOS 26, *) {
            content
        } else if #available(macOS 13.3, *) {
            content.presentationBackground(shape)
        } else {
            content
        }
    }

    @ViewBuilder func glassEffectTransition(_ transition: BackportGlassEffectTransition) -> some View {
        if #available(iOS 26.0, macOS 26, *) {
            content.glassEffectTransition(transition.toTransition)
        } else {
            content
        }
    }

    @ViewBuilder func glassEffect(
        _ backportGlass: BackportGlass = .regular,
        in shape: some Shape = Capsule()
    ) -> some View {
        if #available(iOS 26.0, macOS 26, *) {
            content.glassEffect(backportGlass.toGlass, in: shape)
        } else {
            // Без фона контент лёг бы голым текстом на карту: на iOS 18 стекло
            // эмулирует ultraThinMaterial + тонкая кайма (та же читаемость).
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Theme.stroke, lineWidth: 1))
        }
    }

    @ViewBuilder func glassEffect(
        _ backportGlass: BackportGlass = .regular,
        in shape: some Shape = Capsule(),
        fallbackBackground: some ShapeStyle) -> some View {
            if #available(iOS 26.0, macOS 26, *) {
                content.glassEffect(backportGlass.toGlass, in: shape)
            } else {
                if #available(macOS 12.0, *) {
                    content.background(fallbackBackground, in: shape)
                } else {
                    content
                }
            }
        }

    @ViewBuilder func glassEffectContainer(spacing: CGFloat? = nil) -> some View {
        if #available(iOS 26.0, macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }

    @ViewBuilder func glassEffectUnion(
        id: (some Hashable & Sendable)?,
        namespace: Namespace.ID
    ) -> some View {
        if #available(iOS 26.0, macOS 26, *) {
            content.glassEffectUnion(id: id, namespace: namespace)
        } else {
            content
        }
    }

    @ViewBuilder func glassButtonStyle(fallbackStyle: some PrimitiveButtonStyle = DefaultButtonStyle()) -> some View {
        if #available(iOS 26.0, macOS 26, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(fallbackStyle)
        }
    }

    @ViewBuilder func glassProminentButtonStyle() -> some View {
        if #available(iOS 26.0, macOS 26, *) {
            content.buttonStyle(.glassProminent)
        } else {
            if #available(macOS 12.0, *) {
                content.buttonStyle(.borderedProminent)
            } else {
                content
            }
        }
    }

    @ViewBuilder func backgroundExtensionEffect() -> some View {
        if #available(iOS 26.0, macOS 26, *) {
            content.backgroundExtensionEffect()
        } else {
            content
        }
    }

    @ViewBuilder func scrollEdgeEffectStyle(
        _ style: BackportScrollEdgeEffectStyle?,
        for edges: Edge.Set
    ) -> some View {
        if #available(iOS 26.0, macOS 26, *) {
            content.scrollEdgeEffectStyle(style?.toStyle, for: edges)
        } else {
            content
        }
    }

    @ViewBuilder func scrollEdgeEffectHidden(
        _ hidden: Bool = true,
        for edges: Edge.Set = .all
    ) -> some View {
        if #available(iOS 26.0, macOS 26, *) {
            content.scrollEdgeEffectHidden(hidden, for: edges)
        } else {
            content
        }
    }

    @ViewBuilder func glassEffectID(
        _ id: (some Hashable & Sendable)?,
        in namespace: Namespace.ID
    ) -> some View {
        if #available(iOS 26.0, macOS 26, *) {
            content.glassEffectID(id, in: namespace)
        } else {
            content
        }
    }

    @ViewBuilder func symbolColorRenderingMode(_ mode: BackportSymbolColorRenderingMode?) -> some View {
        if #available(iOS 26.0, macOS 26, *) {
            content.symbolColorRenderingMode(mode?.toMode)
        } else {
            content
        }
    }

    @ViewBuilder func symbolVariableValueMode(_ mode: BackportSymbolVariableValueMode?) -> some View {
        if #available(iOS 26.0, macOS 26, *) {
            content.symbolVariableValueMode(mode?.toMode)
        } else {
            content
        }
    }

    @ViewBuilder func tabViewBottomAccessory(@ViewBuilder content: () -> some View) -> some View {
#if os(macOS)
        self.content
#else
        if #available(iOS 26.0, *) {
            self.content.tabViewBottomAccessory(content: content)
        } else {
            self.content
        }
#endif
    }

    @ViewBuilder func tabBarMinimizeBehavior(_ behavior: BackportTabBarMinimizeBehavior) -> some View {
        if #available(iOS 26.0, macOS 26, *) {
            content.tabBarMinimizeBehavior(behavior.toBehavior)
        } else {
            content
        }
    }

    @ViewBuilder func listSectionMargins(_ edges: Edge.Set = .all, _ length: CGFloat?) -> some View {
        if #available(iOS 26.0, macOS 11, *) {
#if os(iOS)
            content.listSectionMargins(edges, length)
#else
            content
#endif
        } else {
            content
        }
    }

    @ViewBuilder func safeAreaBar<V: View>(edge: VerticalEdge,
                                           alignment: HorizontalAlignment = .center,
                                           spacing: CGFloat? = nil,
                                           @ViewBuilder content: () -> V) -> some View {
        if #available(iOS 26.0, macOS 26, *) {
            self.content.safeAreaBar(edge: edge, alignment: alignment, spacing: spacing, content: content)
        } else {
            self.content.safeAreaInset(edge: edge, alignment: alignment, spacing: spacing, content: content)
        }
    }

    @ViewBuilder func searchToolbarBehavior(_ behavior: BackportSearchToolbarBehavior) -> some View {
        if #available(iOS 26.0, macOS 26, *) {
            switch behavior {
            case .automatic:
                content.searchToolbarBehavior(.automatic)
            case .minimize:
#if os(macOS)
                content.searchToolbarBehavior(.automatic)
#else
                content.searchToolbarBehavior(.minimize)
#endif
            }
        } else {
            content
        }
    }
}

@MainActor
@available(iOS 14, macOS 12, *)
extension Backport where Content: ToolbarContent {
    @ToolbarContentBuilder
    func sharedToolBarBackgroundVisibility(_ visibility: Visibility) -> some ToolbarContent {
        if #available(iOS 26.0, macOS 26, *) {
            content.sharedBackgroundVisibility(visibility)
        } else {
            content
        }
    }
}
