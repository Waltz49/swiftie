import Foundation

enum InformationPaneLinkAction: Equatable {
    case copySeed(String)
    case toggleSection(String, expandAll: Bool)
    case refLevel(optionHeld: Bool)
    case edit
    case copy(fullComment: Bool)
    case delete
}
