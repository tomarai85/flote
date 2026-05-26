import AppKit
import Foundation

enum RichTextStorage {

    static func archive(_ attrString: NSAttributedString) -> Data? {
        do {
            let data = try NSKeyedArchiver.archivedData(
                withRootObject: attrString,
                requiringSecureCoding: true
            )
            return data
        } catch {
            return nil
        }
    }

    static func unarchive(_ data: Data) -> NSAttributedString? {
        // Explicit safe-class allow-list prevents malicious payloads from
        // instantiating unexpected classes (e.g. NSTextAttachment with
        // NSFileWrapper that could trigger disk I/O).
        let allowedClasses: [AnyClass] = [
            NSAttributedString.self,
            NSString.self,
            NSDictionary.self,
            NSNumber.self,
            NSArray.self,
            NSParagraphStyle.self,
            NSMutableParagraphStyle.self,
            NSFont.self,
            NSColor.self,
            NSURL.self,
            NSData.self
        ]
        do {
            let obj = try NSKeyedUnarchiver.unarchivedObject(
                ofClasses: allowedClasses,
                from: data
            )
            return obj as? NSAttributedString
        } catch {
            return nil
        }
    }
}
