//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2021 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import HummingbirdCore
import NIOCore

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin.C
#else
#error("Unsupported platform")
#endif

/// Access environment variables
public struct Environment: Sendable, Decodable, ExpressibleByDictionaryLiteral {
    struct Error: Swift.Error, Equatable {
        enum Value {
            case dotEnvParseError
        }

        private let value: Value
        private init(_ value: Value) {
            self.value = value
        }

        public static var dotEnvParseError: Self { .init(.dotEnvParseError) }
    }

    var values: [String: String]

    /// Initialize from environment variables
    public init() {
        self.values = Self.getEnvironment()
    }

    /// Initialize from dictionary
    public init(values: [String: String]) {
        self.values = Self.getEnvironment()
        for (key, value) in values {
            self.values[key.lowercased()] = value
        }
    }

    /// Initialize from dictionary literal
    public init(dictionaryLiteral elements: (String, String)...) {
        self.values = Self.getEnvironment()
        for element in elements {
            self.values[element.0.lowercased()] = element.1
        }
    }

    /// Initialize from Decodable
    public init(from decoder: Decoder) throws {
        self.values = Self.getEnvironment()
        let container = try decoder.singleValueContainer()
        let decodedValues = try container.decode([String: String].self)
        for (key, value) in decodedValues {
            self.values[key.lowercased()] = value
        }
    }

    /// Get environment variable with name
    /// - Parameter s: Environment variable name
    public func get(_ s: String) -> String? {
        self.values[s.lowercased()]
    }

    /// Get environment variable with name as a certain type
    /// - Parameters:
    ///   - s: Environment variable name
    ///   - as: Type we want variable to be cast to
    public func get<T: LosslessStringConvertible>(_ s: String, as: T.Type) -> T? {
        self.values[s.lowercased()].map { T(String($0)) } ?? nil
    }

    /// Set environment variable
    ///
    /// This sets the variable within this type and also calls `setenv` so future versions
    /// of this type will also have this variable set.
    /// - Parameters:
    ///   - s: Environment variable name
    ///   - value: Environment variable name value
    public mutating func set(_ s: String, value: String?) {
        self.values[s.lowercased()] = value
        if let value {
            setenv(s, value, 1)
        } else {
            unsetenv(s)
        }
    }

    /// Merge two environment variable sets together and return result
    ///
    /// If an environment variable exists in both sets it will choose the version from the second
    /// set of environment variables
    /// - Parameter env: environemnt variables to merge into this environment variable set
    public func merging(with env: Environment) -> Environment {
        .init(rawValues: self.values.merging(env.values) { $1 })
    }

    /// Construct environment variable map
    static func getEnvironment() -> [String: String] {
        var values: [String: String] = [:]
        for item in ProcessInfo.processInfo.environment {
            values[item.key.lowercased()] = item.value
        }
        return values
    }

    /// Create Environment initialised from the `.env` file
    public static func dotEnv(_ dovEnvPath: String = ".env") async throws -> Self {
        guard let dotEnv = await loadDotEnv(dovEnvPath) else { return [:] }
        return try .init(rawValues: self.parseDotEnv(dotEnv))
    }

    /// Load `.env` file into string
    internal static func loadDotEnv(_ dovEnvPath: String = ".env") async -> String? {
        do {
            let fileHandle = try NIOFileHandle(path: dovEnvPath)
            defer {
                try? fileHandle.close()
            }
            let fileRegion = try FileRegion(fileHandle: fileHandle)
            let contents = try fileHandle.withUnsafeFileDescriptor { descriptor in
                [UInt8](unsafeUninitializedCapacity: fileRegion.readableBytes) { bytes, size in
                    size = fileRegion.readableBytes
                    read(descriptor, .init(bytes.baseAddress), size)
                }
            }
            return String(bytes: contents, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Parse a `.env` file
    internal static func parseDotEnv(_ dotEnv: String) throws -> [String: String] {
        enum DotEnvParserState {
            case readingKey
            case skippingEquals(key: String)
            case readingValue(key: String)
        }
        var dotEnvDictionary: [String: String] = [:]
        var parser = Parser(dotEnv)
        var state: DotEnvParserState = .readingKey
        do {
            while !parser.reachedEnd() {
                parser.read(while: \.isWhitespace)

                switch state {
                case .readingKey:
                    // handle empty lines at the end
                    guard !parser.reachedEnd() else { break }

                    // check for comment
                    let c = parser.current()
                    if c == "#" {
                        do {
                            _ = try parser.read(until: \.isNewline)
                            parser.unsafeAdvance()
                        } catch Parser.Error.overflow {
                            parser.moveToEnd()
                            break
                        }
                        continue
                    }
                    let key = try parser.read(until: { $0.isWhitespace || $0 == "=" }).string
                    state = .skippingEquals(key: key)

                case .skippingEquals(let key):
                    let c = try parser.character()
                    // we are expecting an equals
                    guard c == "=" else { throw Error.dotEnvParseError }
                    state = .readingValue(key: key)

                case .readingValue(let key):
                    let value: String
                    if try parser.read("\"") {
                        value = try parser.read(until: { $0 == "\"" }).string
                        parser.unsafeAdvance()
                    } else {
                        value = try parser.read(until: \.isWhitespace, throwOnOverflow: false).string
                    }
                    dotEnvDictionary[key.lowercased()] = value
                    state = .readingKey
                }
            }
            guard case .readingKey = state else { throw Error.dotEnvParseError }
        } catch {
            throw Error.dotEnvParseError
        }
        return dotEnvDictionary
    }

    /// initialize from an already processed dictionary
    private init(rawValues: [String: String]) {
        self.values = rawValues
    }
}

extension Environment: CustomStringConvertible {
    public var description: String {
        String(describing: self.values)
    }
}
