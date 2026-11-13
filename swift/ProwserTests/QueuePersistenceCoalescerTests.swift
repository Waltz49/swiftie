import XCTest
@testable import Prowser

@MainActor
final class QueuePersistenceCoalescerTests: XCTestCase {
    private var writeCount = 0
    private var config: AppConfig!

    override func setUp() {
        super.setUp()
        writeCount = 0
        QueuePersistenceCoalescer.resetSaveInvocationCountForTesting()
        config = ProwserTestSupport.ephemeralAppConfig()
    }

    func testMultipleSchedulesCoalesceToOneWrite() async {
        let coalescer = QueuePersistenceCoalescer { [self] _, _ in
            writeCount += 1
        }
        let file = ImageGenQueueFile()
        coalescer.schedule(file: file, config: config)
        coalescer.schedule(file: file, config: config)
        coalescer.schedule(file: file, config: config)
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(QueuePersistenceCoalescer.saveInvocationCountForTesting, 1)
    }

    func testFlushNowBypassesDebounce() {
        let coalescer = QueuePersistenceCoalescer { [self] _, _ in
            writeCount += 1
        }
        let file = ImageGenQueueFile()
        coalescer.schedule(file: file, config: config)
        coalescer.flushNow(file: file, config: config)
        XCTAssertEqual(writeCount, 1)
    }

    func testSuppressBlocksScheduleAndFlush() {
        let coalescer = QueuePersistenceCoalescer { [self] _, _ in
            writeCount += 1
        }
        let file = ImageGenQueueFile()
        coalescer.incrementSuppress()
        coalescer.schedule(file: file, config: config)
        coalescer.flushNow(file: file, config: config)
        XCTAssertEqual(writeCount, 0)
        coalescer.decrementSuppress()
        coalescer.flushNow(file: file, config: config)
        XCTAssertEqual(writeCount, 1)
    }
}
