// TabletopTerrainAtlasImage.swift
//
// CoreGraphics-only terrain-atlas packing shared by production RealityKit
// material creation and host-side synthetic acceptance tests.
import CoreGraphics
import Foundation

public enum TabletopTerrainAtlasImageBuilder {
    public static func build(
        slotImages: [Int: CGImage],
        layout: TabletopTerrainAtlasLayout,
        fallbackColor: CGColor = CGColor(
            red: 0.55, green: 0.55, blue: 0.55, alpha: 1.0)
    ) -> CGImage? {
        guard layout.isValid,
              layout.atlasWidth > 0, layout.atlasHeight > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: layout.atlasWidth,
            height: layout.atlasHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.interpolationQuality = .none
        ctx.setFillColor(fallbackColor)
        ctx.fill(CGRect(
            x: 0, y: 0,
            width: CGFloat(layout.atlasWidth),
            height: CGFloat(layout.atlasHeight)))

        // Match the image orientation used by the single-frame decode path:
        // logical row 0 becomes texture row 0 (Metal v=0).
        ctx.translateBy(x: 0, y: CGFloat(layout.atlasHeight))
        ctx.scaleBy(x: 1, y: -1)

        for (slot, image) in slotImages {
            guard slot >= 0, slot < layout.slotCount,
                  image.width == layout.cellWidth,
                  image.height == layout.cellHeight else { continue }

            let originX = layout.slotOriginX(slot)
            let originY = layout.slotOriginY(slot)
            let contentX = layout.contentOriginX(slot)
            let contentY = layout.contentOriginY(slot)
            ctx.draw(image, in: CGRect(
                x: CGFloat(contentX), y: CGFloat(contentY),
                width: CGFloat(layout.cellWidth),
                height: CGFloat(layout.cellHeight)))

            let gutter = layout.gutterPixels
            guard gutter > 0,
                  let leftEdge = image.cropping(to: CGRect(
                    x: 0, y: 0, width: 1, height: CGFloat(layout.cellHeight))),
                  let rightEdge = image.cropping(to: CGRect(
                    x: CGFloat(layout.cellWidth - 1), y: 0,
                    width: 1, height: CGFloat(layout.cellHeight)))
            else { continue }

            ctx.draw(leftEdge, in: CGRect(
                x: CGFloat(originX), y: CGFloat(contentY),
                width: CGFloat(gutter), height: CGFloat(layout.cellHeight)))
            ctx.draw(rightEdge, in: CGRect(
                x: CGFloat(contentX + layout.cellWidth), y: CGFloat(contentY),
                width: CGFloat(gutter), height: CGFloat(layout.cellHeight)))

            // Decoded images are pre-flipped, so memory bottom is the visual
            // top before this context's flip. Replicate both vertical edges
            // even for one-row atlases: their padded content boundaries are
            // interior texture coordinates where clamping does not apply.
            if let topEdge = image.cropping(to: CGRect(
                x: 0, y: CGFloat(layout.cellHeight - 1),
                width: CGFloat(layout.cellWidth), height: 1)),
               let bottomEdge = image.cropping(to: CGRect(
                x: 0, y: 0, width: CGFloat(layout.cellWidth), height: 1)),
               let topLeft = image.cropping(to: CGRect(
                x: 0, y: CGFloat(layout.cellHeight - 1),
                width: 1, height: 1)),
               let topRight = image.cropping(to: CGRect(
                x: CGFloat(layout.cellWidth - 1),
                y: CGFloat(layout.cellHeight - 1),
                width: 1, height: 1)),
               let bottomLeft = image.cropping(to: CGRect(
                x: 0, y: 0, width: 1, height: 1)),
               let bottomRight = image.cropping(to: CGRect(
                x: CGFloat(layout.cellWidth - 1), y: 0,
                width: 1, height: 1)) {
                ctx.draw(topEdge, in: CGRect(
                    x: CGFloat(contentX), y: CGFloat(originY),
                    width: CGFloat(layout.cellWidth),
                    height: CGFloat(gutter)))
                ctx.draw(bottomEdge, in: CGRect(
                    x: CGFloat(contentX),
                    y: CGFloat(contentY + layout.cellHeight),
                    width: CGFloat(layout.cellWidth),
                    height: CGFloat(gutter)))
                ctx.draw(topLeft, in: CGRect(
                    x: CGFloat(originX), y: CGFloat(originY),
                    width: CGFloat(gutter), height: CGFloat(gutter)))
                ctx.draw(topRight, in: CGRect(
                    x: CGFloat(contentX + layout.cellWidth),
                    y: CGFloat(originY),
                    width: CGFloat(gutter), height: CGFloat(gutter)))
                ctx.draw(bottomLeft, in: CGRect(
                    x: CGFloat(originX),
                    y: CGFloat(contentY + layout.cellHeight),
                    width: CGFloat(gutter), height: CGFloat(gutter)))
                ctx.draw(bottomRight, in: CGRect(
                    x: CGFloat(contentX + layout.cellWidth),
                    y: CGFloat(contentY + layout.cellHeight),
                    width: CGFloat(gutter), height: CGFloat(gutter)))
            }
        }
        return ctx.makeImage()
    }
}
