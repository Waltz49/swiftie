import CoreML
import Foundation

/// Safe MLMultiArray ↔ [Float] (avoid assuming contiguous `dataPointer` layout).
enum MLMultiArrayHelpers {
    static func readFloats(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        var out = [Float](repeating: 0, count: count)
        switch array.dataType {
        case .float32:
            for i in 0 ..< count {
                out[i] = array[i].floatValue
            }
        case .double:
            for i in 0 ..< count {
                out[i] = Float(array[i].doubleValue)
            }
        default:
            for i in 0 ..< count {
                out[i] = array[i].floatValue
            }
        }
        return out
    }

    static func writeFloats(_ values: [Float], into array: MLMultiArray) {
        let count = min(values.count, array.count)
        for i in 0 ..< count {
            array[i] = NSNumber(value: values[i])
        }
        if values.count < array.count {
            for i in values.count ..< array.count {
                array[i] = 0
            }
        }
    }
}
