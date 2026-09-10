//
//  ShotBankView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreVideo
import SwiftUI
import TingraComposition
import TingraEventBus
import TingraPlugInKit

/// The main window's **shot bank**: one tile per shot of the active preset,
/// in switcher order, under the monitors — the row that used to list every
/// video input and now lists what the operator can actually take
/// (ARCHITECTURE.md, "The shot bank").
///
/// **A tile is a shot.** It is captioned beneath with the shot's name — the
/// way the monitors above are captioned with the shot they show, rather than
/// a badge on the picture, which on a thumbnail this size covered a quarter of
/// it — and wears the tally border the monitors' convention gives it: red on
/// program, green staged, none idle. For its picture it draws the latest frame
/// of the layer that covers most of the frame
/// (``ShotBankTile/thumbnailInput(of:)``), pulled through the same
/// ``InputFrameSource`` the multiview's tiles read: the compositor's
/// read-only slot, drawn and dropped. A shot with more than one layer wears a
/// stacked-layers glyph so one input's picture is not mistaken for the whole
/// composition; a shot with no layers is black over its caption. Clicking a
/// tile stages that shot on preview — staging is not taking, and Take stays
/// the one step to air. The tile's context menu is the shared
/// ``ShotContextMenu`` on the `switcher` surface: Move Left / Move Right, and
/// an immediate Remove Shot.
///
/// **A dashed tile is a transient shot** — the app made it to stage an input
/// the operator clicked in the sidebar, and it will be discarded when they
/// look away unless they **Keep** it, edit it, or take it to air
/// (``EngineModel/stagePreview(showing:)``). It sits last, with a Keep button
/// on it, so the bank says outright which shot is not yet part of the show.
///
/// **The bank is where an input becomes a shot.** A sidebar camera, display,
/// or video generator row dragged here inserts a full-frame authored shot of
/// it — before or after the tile it lands on by which half was hit, or at the
/// end when it lands on empty row — and the Add Shot menu (``AddShotMenu``)
/// beside the **Shots** heading above the bank, the same items as the Shots
/// menu's and the sidebar's Add Shot submenus, adds one by choice. An empty bank shows a placeholder
/// naming both ways in. Reordering stays on the
/// context menu rather than on drag, so a tile's click is always a stage and
/// never half a drag; a drop's payload is an *input*, never a shot, so the
/// two gestures cannot be confused.
///
/// Every control reports its own `tap` where it executes (EVENTS.md, "The
/// `tap` convention").
struct ShotBankView: View {
    /// The engine model: the shots, the buses, and the frames.
    let model: EngineModel

    /// The tiles' picture height; each is 16:9 within it, and the row is
    /// this plus a caption. Passed in rather than measured because the bank
    /// sits in a scrolling column that proposes an unbounded height, so the
    /// caller derives it from the window's width — normally through
    /// ``height(forRowWidth:)``.
    let height: CGFloat

    /// What Rename… in a tile's context menu does after its `tap`: the owning
    /// view opens its rename dialog over the shot handed back.
    let onRename: (Shot) -> Void

    /// The tile a drag is currently over, or nil — drawn with an accent
    /// outline so the operator can see where the shot will land.
    @State private var targetedTileID: ShotID?

    /// Whether a drag is over the row's empty end, where a drop appends.
    @State private var isEndTargeted = false

    /// The gap between tiles.
    private static let tileSpacing: CGFloat = 8

    /// The gap between a tile's picture and its caption.
    private static let captionSpacing: CGFloat = 4

    /// How many 16:9 tiles the row is sized to show across its width before
    /// it scrolls. Sizing by count keeps the tiles proportional to the window
    /// — the same reason the monitors above take their height from the width
    /// — while leaving each large enough to read a face or a pattern in.
    private static let tilesAcrossRow: CGFloat = 7

    /// The shortest the row may be, so tiles stay readable in a window near
    /// the 640-point minimum width.
    private static let minimumHeight: CGFloat = 60

    /// The tiles' corner radius — ``MonitorTile``'s, so the borders drawn
    /// here sit on the same edge.
    private static let cornerRadius: CGFloat = 8

    /// The picture height the bank's tiles need at a given row width: one
    /// row of 16:9 pictures, ``tilesAcrossRow`` of them fitting across the
    /// width. The captions beneath add their own line; the row's height is
    /// the sum, taken from the tiles themselves.
    ///
    /// - Parameter width: The width the row spans.
    /// - Returns: The height to pass as ``height``.
    static func height(forRowWidth width: CGFloat) -> CGFloat {
        let tileWidth = (width - tileSpacing * (tilesAcrossRow - 1)) / tilesAcrossRow
        return max(minimumHeight, tileWidth * 9 / 16)
    }

    /// The row: the shot tiles, or the placeholder when there are none,
    /// scrolling horizontally when there are more than fit.
    var body: some View {
        let tiles = ShotBankTile.tiles(
            shots: model.shots,
            onProgram: model.activeShotID,
            onPreview: model.previewShotID
        )
        let tileWidth = height * model.programAspectRatio
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Self.tileSpacing) {
                if tiles.isEmpty {
                    placeholderTile(width: tileWidth * 2)
                }
                ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                    shotTile(tile, at: index, width: tileWidth)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The row itself takes a drop that lands on no tile: appended.
        .dropDestination(for: DraggedInput.self) { items, _ in
            drop(items, at: nil)
        } isTargeted: { targeted in
            isEndTargeted = targeted
        }
        .overlay {
            if isEndTargeted {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
    }

    /// One shot's tile: the picture, staging the shot on click, over its
    /// caption, with the shared context menu on both, and taking a dropped
    /// input before or after itself.
    ///
    /// The picture alone is the button, so Keep and the drop outline ride
    /// over the picture and not the caption; the context menu and the drop
    /// target span both, so a right-click or a drop on the name behaves as one
    /// on the picture.
    ///
    /// - Parameters:
    ///   - tile: The tile to draw.
    ///   - index: The shot's position in the switcher order, for a drop.
    ///   - width: The tile's width.
    /// - Returns: The tile.
    private func shotTile(_ tile: ShotBankTile, at index: Int, width: CGFloat) -> some View {
        VStack(spacing: Self.captionSpacing) {
            Button {
                model.eventBus.tap(
                    "shotBank.tile",
                    domain: .composition,
                    params: ["shot": .string(tile.id.rawValue), "name": .string(tile.name)]
                )
                model.setPreview(tile.id)
            } label: {
                picture(for: tile, width: width)
            }
            .buttonStyle(.plain)
            .help(Text("Stage on preview", comment: "Tooltip on an input tile that stages it on preview"))
            // Keep rides over the button rather than inside its label, so its
            // click is its own and never also a stage.
            .overlay(alignment: .bottomLeading) {
                if tile.isTransient {
                    keepButton(for: tile)
                }
            }
            .overlay {
                if targetedTileID == tile.id {
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }

            // The monitors' caption style, with the shot's stage shortcut
            // after the name for the first nine, so the bank answers "which
            // shot is ⌘4" where the operator is looking.
            caption(for: tile, at: index)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: width)
        }
        .contextMenu {
            if let shot = model.shots.first(where: { $0.id == tile.id }) {
                ShotContextMenu(model: model, shot: shot, surface: .switcher, onRename: onRename) { shot in
                    // Immediate, no confirmation: shots are quick to create,
                    // switch, and discard (GLOSSARY.md, "Shot").
                    Task { await model.removeShot(shot.id) }
                }
            }
        }
        .dropDestination(for: DraggedInput.self) { items, location in
            // The half the drop lands in says which side of this tile the new
            // shot goes on.
            drop(items, at: location.x < width / 2 ? index : index + 1)
        } isTargeted: { targeted in
            if targeted {
                targetedTileID = tile.id
            } else if targetedTileID == tile.id {
                targetedTileID = nil
            }
        }
    }

    /// A tile's caption: the shot's name, followed in parentheses by the key
    /// that stages it (``ProductionShortcut/stageShotSymbol(forIndex:)``) for
    /// a shot in the first nine positions, and the bare name past them.
    ///
    /// - Parameters:
    ///   - tile: The tile to caption.
    ///   - index: The shot's position in the switcher order.
    /// - Returns: The caption.
    private func caption(for tile: ShotBankTile, at index: Int) -> Text {
        if let symbol = ProductionShortcut.stageShotSymbol(forIndex: index) {
            return Text(
                "\(tile.name) (\(symbol))",
                comment: "Shot bank tile caption: the shot's name, then the shortcut that stages it, e.g. Default (⌘1)"
            )
        }
        return Text(verbatim: tile.name)
    }

    /// A tile's picture: the thumbnail, unbadged, with the tally border — or
    /// the transient dash — and the stacked-layers glyph.
    ///
    /// - Parameters:
    ///   - tile: The tile to draw.
    ///   - width: The picture's width.
    /// - Returns: The picture.
    private func picture(for tile: ShotBankTile, width: CGFloat) -> some View {
        MonitorTile(
            source: thumbnailSource(for: tile),
            label: nil,
            badgeTint: tile.tally.badgeTint,
            aspectRatio: model.programAspectRatio,
            // A transient tile draws its own dashed border in the tally's
            // colour, so the solid one stays off.
            borderTint: tile.isTransient ? nil : tile.tally.borderTint
        )
        .frame(width: width, height: height)
        .overlay {
            if tile.isTransient {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(
                        tile.tally.borderTint ?? .secondary,
                        style: StrokeStyle(lineWidth: 3, dash: [6, 4])
                    )
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if tile.layerCount > 1 {
                Image(systemName: "square.3.layers.3d")
                    .font(.caption.weight(.semibold))
                    .padding(6)
                    .background(.black.opacity(0.6), in: .capsule)
                    .foregroundStyle(.white)
                    .padding(8)
                    .accessibilityLabel(
                        Text(
                            "Multiple layers",
                            comment: "Accessibility label of the glyph on a shot tile with more than one layer"
                        )
                    )
            }
        }
    }

    /// The Keep button on a transient tile: promotes the shot to authored, so
    /// it persists and stays when something else is staged.
    ///
    /// - Parameter tile: The transient tile.
    /// - Returns: The button.
    private func keepButton(for tile: ShotBankTile) -> some View {
        Button {
            model.eventBus.tap(
                "shotBankKeep.button",
                domain: .composition,
                params: ["shot": .string(tile.id.rawValue), "name": .string(tile.name)]
            )
            model.keepShot(tile.id)
        } label: {
            Text("Keep", comment: "Button on a transient shot tile keeping the shot in the preset")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .padding(8)
        .help(
            Text(
                "Keep this shot in the preset",
                comment: "Tooltip on a transient shot tile's Keep button"
            )
        )
    }

    /// The placeholder an empty bank shows, naming both ways to put a shot in
    /// it.
    ///
    /// - Parameter width: The placeholder's width — two tiles', for the text.
    /// - Returns: The placeholder.
    private func placeholderTile(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius)
            .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .frame(width: width, height: height)
            .overlay {
                Text(
                    "Drag a camera, display, or generator here, or choose Add Shot.",
                    comment: "Placeholder tile in the shot bank when the preset has no shots"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(12)
            }
    }

    /// Where a tile reads its picture: the dominant layer's input, or nothing
    /// for a shot with no layers.
    ///
    /// - Parameter tile: The tile.
    /// - Returns: The frame source.
    private func thumbnailSource(for tile: ShotBankTile) -> any MonitorFrameSource {
        if let input = tile.thumbnailInput {
            return InputFrameSource(model: model, id: input)
        }
        return EmptyFrameSource()
    }

    /// Handles a dropped input: inserts a full-frame authored shot of it at
    /// the given position, or appends. A payload naming no discovered video
    /// input is refused — nothing else produces this type, so that is a
    /// device that went away mid-drag.
    ///
    /// - Parameters:
    ///   - items: The dropped payloads; the first is used.
    ///   - index: The switcher position to insert at, or nil to append.
    /// - Returns: Whether the drop was accepted.
    private func drop(_ items: [DraggedInput], at index: Int?) -> Bool {
        guard let input = items.first?.id, model.videoInputs.contains(where: { $0.id == input }) else {
            return false
        }
        model.eventBus.tap(
            "shotBank.drop",
            domain: .composition,
            params: ["input": .string(input.rawValue), "index": .int(index ?? model.shots.count)]
        )
        Task { await model.addShot(showing: input, at: index) }
        return true
    }
}

/// A frame source with no frames: what a tile draws for a shot with no
/// layers — black over its caption, ``MonitorView``'s clear colour.
private struct EmptyFrameSource: MonitorFrameSource {
    /// Always nil: nothing to draw.
    var latest: CVPixelBuffer? { nil }
}
