//
//  CreateDevice.swift
//  SnapOrthoBackend
//
//  Created by Alex Baur on 6/17/25.
//


import Fluent

struct CreateDevice: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema("devices")
            .id()
            .field("device_token", .string, .required)
            .field("learn_user_id", .string, .required)
            .field("platform", .string, .required)
            .field("app_version", .string, .required)
            .field("last_seen", .datetime, .required)
            .unique(on: "device_token")
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema("devices").delete()
    }
}
