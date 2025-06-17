//
//  Video.swift
//  SnapOrthoBackend
//
//  Created by Alex Baur on 6/17/25.
//

import Vapor
import Fluent
import Foundation

struct Video: Content {
    let id: String
    let title: String
    let description: String
    let youtubeURL: String
    let category: String
    let isPreview: Bool
}
