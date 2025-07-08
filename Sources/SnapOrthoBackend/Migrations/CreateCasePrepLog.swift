//
//  CreateCasePrepLog.swift
//  SnapOrthoBackend
//
//  Created by Alex Baur on 7/8/25.
//


import Fluent

struct CreateCasePrepLog: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema("case_prep_logs")
            .id()
            .field("prompt", .string, .required)
            .field("response_json", .string, .required)
            .field("was_helpful", .bool)
            .field("user_feedback", .string)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema("case_prep_logs").delete()
    }
}
