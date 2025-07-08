import Fluent
import Vapor

final class CasePrepLog: Model, Content, @unchecked Sendable {
    static let schema = "case_prep_logs"

    @ID(key: .id) var id: UUID?
    @Field(key: "prompt") var prompt: String
    @Field(key: "response_json") var responseJSON: String
    @OptionalField(key: "was_helpful") var wasHelpful: Bool?
    @OptionalField(key: "user_feedback") var userFeedback: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() { }

    init(id: UUID? = nil,
         prompt: String,
         responseJSON: String,
         wasHelpful: Bool? = nil,
         userFeedback: String? = nil) {
        self.id = id
        self.prompt = prompt
        self.responseJSON = responseJSON
        self.wasHelpful = wasHelpful
        self.userFeedback = userFeedback
    }
}
