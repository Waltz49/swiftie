import XCTest
@testable import Prowser

final class LoRACatalogSettingsMigrationTests: XCTestCase {
    func testEmptyCatalogStampsDiskFirstSchemaWithoutPython() {
        let migrated = LoRACatalogSettings.migrateCatalog([:])
        XCTAssertEqual(migrated[LoRACatalogSettings.catalogSchemaKey] as? String, LoRACatalogSettings.diskFirstSchema)
        XCTAssertFalse(LoRACatalogSettings.needsPythonDiskFirstMigration(migrated))
    }

    func testLegacyBuiltinOverrideNeedsPythonMigration() {
        let lc: [String: Any] = [
            LoRACatalogSettings.userEntriesKey: [:],
            LoRACatalogSettings.entryOverridesKey: [
                "some_builtin_preset": ["scale": 0.7],
            ],
        ]
        XCTAssertTrue(LoRACatalogSettings.needsPythonDiskFirstMigration(lc))
        let migrated = LoRACatalogSettings.migrateCatalog(lc)
        XCTAssertNil(migrated[LoRACatalogSettings.catalogSchemaKey])
    }
}