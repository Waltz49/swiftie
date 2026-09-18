import XCTest
@testable import Prowser

final class AppEventBusTests: XCTestCase {
    @MainActor
    func testSubscribeEmitUnsubscribe() {
        let bus = AppEventBus()
        var count = 0
        let token = bus.subscribe(.settingsChanged) { _ in count += 1 }
        bus.emit(.settingsChanged)
        XCTAssertEqual(count, 1)
        bus.unsubscribe(.settingsChanged, token: token)
        bus.emit(.settingsChanged)
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testSubscriptionBagRemovesHandlersOnInvalidate() {
        let bus = AppEventBus()
        var count = 0
        let bag = EventBusSubscriptionBag(bus: bus)
        bag.subscribe(.filterPatternChanged) { _ in count += 1 }
        bus.emit(.filterPatternChanged, payload: .string("*"))
        XCTAssertEqual(count, 1)
        bag.invalidate()
        bus.emit(.filterPatternChanged, payload: .string("*.jpg"))
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testModelEventBridgeFilterPatternEmitsOnce() {
        let bus = AppEventBus()
        let bridge = ModelEventBridge(eventBus: bus)
        var emitCount = 0
        _ = bus.subscribe(.filterPatternChanged) { _ in emitCount += 1 }
        let filter = FilterSettingsModel(config: nil, eventBridge: bridge)
        filter.setFilterPattern("*.png", persist: false)
        XCTAssertEqual(emitCount, 1)
        filter.setFilterPattern("*.png", persist: false)
        XCTAssertEqual(emitCount, 1)
    }

    @MainActor
    func testFileDataModelBridgeEmitsDisplayedImages() {
        let bus = AppEventBus()
        let bridge = ModelEventBridge(eventBus: bus)
        var paths: [String]?
        _ = bus.subscribe(.displayedImagesChanged) { event in
            if case .strings(let value) = event.payload {
                paths = value
            }
        }
        let model = FileDataModel(eventBridge: bridge)
        model.setDisplayedImages(["/tmp/a.jpg", "/tmp/b.jpg"])
        XCTAssertEqual(paths, ["/tmp/a.jpg", "/tmp/b.jpg"])
    }
}
