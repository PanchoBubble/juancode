import Testing
@testable import JuancodeCore

/// Remote-grid adoption math (juancode-slz): while a web/phone viewer owns the
/// pty grid and the native pane is pool-hidden, the frozen Ghostty surface is
/// sized to the remote grid so its reflow matches the pty. These tests verify
/// the point-size math survives Ghostty's own points→pixels→grid round-trip.
@Suite struct RemoteGridFitTests {
    /// Ghostty's grid computation: pixel size is `floor(points * scale)`, the
    /// grid is `floor(pixels / cellPixels)` per axis.
    private func ghosttyGrid(widthPts: Double, heightPts: Double, scale: Double,
                             cellW: Int, cellH: Int) -> (cols: Int, rows: Int) {
        let px = ((widthPts * scale).rounded(.down), (heightPts * scale).rounded(.down))
        return (cols: Int(px.0) / cellW, rows: Int(px.1) / cellH)
    }

    @Test func onlyARemoteOwnerIsWorthAdopting() {
        #expect(RemoteGridFit.isRemote(owner: "ws-client-7") == true)
        // The local owner IS this surface, and an unclaimed grid has no driver.
        #expect(RemoteGridFit.isRemote(owner: GridArbiter.localOwner) == false)
        #expect(RemoteGridFit.isRemote(owner: nil) == false)
    }

    @Test(arguments: [1.0, 1.5, 2.0, 2.5]) func roundTripsToTheExactGrid(scale: Double) {
        // Typical phone/web grids against typical Retina cell metrics.
        for (cols, rows, cellW, cellH) in [(48, 22, 18, 38), (80, 24, 14, 30), (211, 57, 17, 37)] {
            let size = RemoteGridFit.surfacePointSize(cols: cols, rows: rows,
                                                      cellWidthPx: cellW, cellHeightPx: cellH,
                                                      scale: scale)
            let grid = ghosttyGrid(widthPts: size.width, heightPts: size.height,
                                   scale: scale, cellW: cellW, cellH: cellH)
            #expect(grid.cols == cols)
            #expect(grid.rows == rows)
        }
    }

    @Test func degenerateInputsYieldZeroSoTheCallerSkipsAdoption() {
        #expect(RemoteGridFit.surfacePointSize(cols: 0, rows: 24, cellWidthPx: 18,
                                               cellHeightPx: 38, scale: 2).width == 0)
        #expect(RemoteGridFit.surfacePointSize(cols: 80, rows: -1, cellWidthPx: 18,
                                               cellHeightPx: 38, scale: 2).height == 0)
        #expect(RemoteGridFit.surfacePointSize(cols: 80, rows: 24, cellWidthPx: 0,
                                               cellHeightPx: 38, scale: 2).width == 0)
        #expect(RemoteGridFit.surfacePointSize(cols: 80, rows: 24, cellWidthPx: 18,
                                               cellHeightPx: 38, scale: 0).width == 0)
    }

    @Test func padNeverAddsAColumnOrRow() {
        // The sub-cell pad guards float truncation but must stay under one cell.
        let size = RemoteGridFit.surfacePointSize(cols: 80, rows: 24, cellWidthPx: 2,
                                                  cellHeightPx: 2, scale: 1)
        let grid = ghosttyGrid(widthPts: size.width, heightPts: size.height,
                               scale: 1, cellW: 2, cellH: 2)
        #expect(grid.cols == 80)
        #expect(grid.rows == 24)
    }
}
