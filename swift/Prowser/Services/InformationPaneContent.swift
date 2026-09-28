import Foundation

struct InformationPaneContent: Equatable {
    var filenameSection: InformationFilenameSection
    var descriptionSection: InformationDescriptionSection
}

struct InformationFilenameSection: Equatable {
    var title: String
    var sectionKey: String
    var expanded: Bool
    var fieldRows: [InformationFieldRow]
    var borderedTable: Bool
}

struct InformationFieldRow: Equatable {
    var label: String
    var value: String
}

struct InformationDescriptionSection: Equatable {
    var body: InformationDescriptionBody
}

enum InformationDescriptionBody: Equatable {
    case addUserComment
    case blocks([InformationDescriptionBlock])
}

struct InformationDescriptionBlock: Equatable {
    /// Collapsible section key when recognized; nil renders a static bold header.
    var sectionKey: String?
    var title: String
    var expanded: Bool
    var parts: [InformationDescriptionPart]
}

enum InformationDescriptionPart: Equatable {
    case plainText(String)
    case modelTable([InformationModelTableRow])
}

struct InformationModelTableRow: Equatable {
    var label: String
    var value: InformationModelValue
    var elideValue: Bool
    var fullWidth: Bool
}

enum InformationModelValue: Equatable {
    case plain(String)
    case bold(String)
    case copySeed(String)
}

struct InformationReferenceSpan: Equatable {
    var text: String
    var isReferenceLink: Bool
}
