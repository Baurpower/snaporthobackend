

import Vapor

struct ImageMetadata: Content {
    let region: String      // e.g. “wrist”
    let caseId: String      // e.g. “wrist001”
    let imageType: String   // e.g. “diag”, “class”
    let index: Int          // 1, 2, …
    let url: String         // public HTTPS URL
}
