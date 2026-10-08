import Foundation
import Testing
@testable import RijiKit
@testable import RijiUI

@Suite("performance")
struct PerformanceTests {
    /// 示例数据约四个月、几百条记录：生成与读取都必须很快（真实一年的数据量级）。
    @MainActor @Test func seedingAndReadingStayFast() throws {
        let start = Date()
        let model = RijiModel.preview()
        let seeded = Date().timeIntervalSince(start)
        let readStart = Date()
        for day in model.days { _ = model.stats(on: day.date) }
        _ = model.heatmap
        _ = model.streak
        let read = Date().timeIntervalSince(readStart)
        print("seed \(seeded)s, read \(read)s, records \(model.book.store.state.count)")
        #expect(seeded < 2.0)
        #expect(read < 0.5)
    }
}
