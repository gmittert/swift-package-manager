/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Foundation

/// File system information for a particular file.
public struct FileInfo: Equatable, Codable {

    /// File system entity kind.
    public enum Kind: String, Codable {
        case file, directory, symlink, blockdev, chardev, socket, unknown

        fileprivate init(type: FileAttributeType) {
            switch type {
            case .typeRegular:          self = .file
            case .typeDirectory:        self = .directory
            case .typeSymbolicLink:     self = .symlink
            case .typeBlockSpecial:     self = .blockdev
            case .typeCharacterSpecial: self = .chardev
            case .typeSocket:           self = .socket
            default:
                self = .unknown
            }
        }
    }

    /// The device number.
    public let device: UInt64

    /// The inode number.
    public let inode: UInt64

    /// The size of the file.
    public let size: UInt64

    /// The modification time of the file.
    public let modTime: Date

    /// Kind of file system entity.
    public let posixPermissions: Int16

    /// Kind of file system entity.
    public let kind: Kind

    public init(_ attrs: [FileAttributeKey : Any]) {
        self.device = attrs[.deviceIdentifier] as! UInt64
        self.inode = attrs[.systemFileNumber] as! UInt64
        self.posixPermissions = (attrs[.posixPermissions] as! NSNumber).int16Value
        self.kind = Kind(type: attrs[.type] as! FileAttributeType)
        self.size = attrs[.size] as! UInt64
        self.modTime = attrs[.modificationDate] as! Date
    }
}
