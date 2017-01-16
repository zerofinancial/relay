//
//  Relay.swift
//  Relay
//
//  Created by Evan Kimia on 12/20/16.
//  Copyright © 2016 zero. All rights reserved.
//

import Foundation
import GRDB
import CocoaLumberjack


public class Relay: DDAbstractLogger, URLSessionTaskDelegate {
    
    private var _identifier: String

    /// The relay identifier is used to segment different relays to different
    /// databases and act as identifiers for URLSessions. If you are using multiple
    /// relays, please use unique identifiers.
    public var identifier: String {
        return _identifier
    }
    
    /// The maximum amount of logs to store before older log records are discarded.
    /// Discarding logs will occur on the next log logged to the database.
    public var maxNumberOfLogs = 10000

    /// `RelayDelegate` is used to report successful/failed log uploads.
    public weak var delegate: RelayDelegate?
    
    /// The number of upload retries before the log is deleted.
    /// A nil value means it will retry indefinitely.
    public var uploadRetries = 3
    
    /// Internal dbQueue, marked as internal for use when running tests.
    var dbQueue: DatabaseQueue?
    
    private var _configuration: RelayRemoteConfiguration
    
    /// Represents the network connection settings used when firing off network tasks.
    /// Changing the host and/or additional headers will update pending log uploads
    /// automatically.
    public var configuration: RelayRemoteConfiguration {
        get {
            return _configuration
        }
        set {
            guard _configuration != newValue else { return }
            _configuration = newValue
            urlSession?.getAllTasks { [weak self] tasks in
                self?.recreatePendingUploadTasksIfNeeded(tasks: tasks)
            }
        }
    }

    /// Completion handler passed from the appDelegate's [application(_:handleEventsForBackgroundURLSession:completionHandler:) method](https://developer.apple.com/reference/uikit/uiapplicationdelegate/1622941-application)
    var sessionCompletionHandler: (() -> Void)?

    /// The active session to cut down on conditionals between testing and production.
    var urlSession: URLSessionProtocol?

    /// Initializes a relay.
    ///
    /// - Parameters:
    ///   - identifier: the identifier to be used for this relay. Each relay maintains it's own
    ///                 internal sqlite database for bookkeeping.
    ///
    ///   - configuration: see the documentation for `RelayRemoteConfiguration` for more information.
    ///
    ///   - testSession: only to be used when running tests!
    required public init(identifier: String, configuration: RelayRemoteConfiguration, testSession: URLSessionProtocol? = nil) {
        
        _identifier = identifier
        if testSession != nil && !isRunningUnitTests() {
            fatalError("testSession can only be used when running unit tests.")
        }
        self._configuration = configuration
        
        do {
            let dbQueue = try DatabaseQueue(path: try getRelayDirectory() + identifier + ".sqlite")
            self.dbQueue = dbQueue
            
            try dbQueue.inDatabase { db in
                guard try !db.tableExists(identifier) else { return }
                
                try Relay.makeTable(db: db)
            }
        } catch {
            #if DEBUG
                fatalError("SQL error during initialization: \(error)")
            #endif
        }

        super.init()

        if testSession != nil {
            urlSession = testSession
        } else {
            let backgroundConfig = URLSessionConfiguration.background(withIdentifier: identifier)
            urlSession = URLSession(configuration: backgroundConfig,
                                    delegate: self,
                                    delegateQueue: nil)
        }
        
        cleanup()
    }
    
    private static func makeTable(db: Database) throws {
            try db.create(table: LogRecord.TableName) { t in
                t.column("uuid", .text).primaryKey()
                t.column("message", .text)
                t.column("flag", .integer).notNull()
                t.column("level", .integer).notNull()
                t.column("context", .text)
                t.column("file", .text)
                t.column("function", .text)
                t.column("line", .integer)
                t.column("date", .datetime)
                t.column("upload_task_id", .integer)
                t.column("upload_retries", .integer).notNull().defaults(to: 0)
            }
    }

    
    /// Call in `application(_:handleEventsForBackgroundURLSession:completionHandler:)` in order
    /// for a relay to finish processing a log record once it succeeds/fails to upload. 
    ///
    /// - see also: [application(_:handleEventsForBackgroundURLSession:completionHandler:) documentation](https://developer.apple.com/reference/uikit/uiapplicationdelegate/1622941-application)
    ///
    /// - Parameters:
    ///   - identifier: The identifier passed from `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    ///                 If the identifer doesn't match the function will exit.
    ///
    ///   - completionHandler: The completion handler passed from `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    ///
    public func handleRelayUrlSessionEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == self.identifier else { return }
        sessionCompletionHandler = completionHandler
    }
    

    /// Removes all logs from the internal database. Logs already passed to the system for uploading will not be cancelled.
    func reset() {
        do {
            try dbQueue?.inDatabase({ db in
                try db.drop(table: LogRecord.TableName)
                try Relay.makeTable(db: db)
            })
        } catch {
            print("SQL error has occured when resetting the database: \(error)")
        }
    }
    
    
    /// Uploads all logs to the server.
    func flushLogs() {
        do {
            try dbQueue?.inDatabase({ db in
                let logRecords = try LogRecord.filter(Column("upload_task_id") == nil).fetchAll(db)
                for record in logRecords {
                    do {
                        uploadLogRecord(logRecord: record, db: db)
                        try record.update(db)
                    } catch {
                        print(error)
                    }
                }
            })
        } catch {
            print("SQL error when flushing logs: \(error)")
        }
    }
    

    /// Helper function to create and upload an `URLSessionTask` to the server.
    ///
    /// - Parameters:
    ///   - logRecord: record to be uploaded.
    ///   - db: database instance.
    ///
    private func uploadLogRecord(logRecord: LogRecord, db: Database) {
        do {
            let logUploadRequest: URLRequest = {
                var request = URLRequest(url: (configuration.host))
                request.httpMethod = "POST"
                if let additionalHTTPHeaders = configuration.additionalHttpHeaders {
                    for (headerName, headerValue) in additionalHTTPHeaders {
                        request.setValue(headerValue, forHTTPHeaderField: headerName)
                    }
                }
                return request
            }()
            
            let jsonData = try JSONSerialization.data(withJSONObject: logRecord.dict)
            
            let fileURL = relayPath().appendingPathComponent("\(logRecord.uuid)")
            try jsonData.write(to: fileURL, options: .atomic)

            let task = urlSession?.uploadTask(with: logUploadRequest, fromFile: fileURL)
            
            logRecord.uploadTaskID = task?.taskIdentifier
            try logRecord.update(db)
            task?.resume()
        } catch {
            print("SQL error during upload process: \(error)")
        }
    }
    
    
    /// Checks pending tasks to ensure they have the appropriate settings from the current `RelayRemoteConfiguration`
    func recreatePendingUploadTasksIfNeeded(tasks: [URLSessionTask]) {
        
        /// Returns true if the task's request aligns with the current `RelayRemoteConfiguration`
        ///
        /// - Parameter task
        /// - Returns: Bool
        func checkTaskRequest(task: URLSessionTask) -> Bool {
            guard let request = task.currentRequest, let url = request.url else { return false }
            
            if let headers = configuration.additionalHttpHeaders, let taskHeaders = request.allHTTPHeaderFields {
                for (key, value) in headers {
                    if let matchingRequestHeader = taskHeaders[key], matchingRequestHeader != value {
                        return false
                    } else if taskHeaders[key] == nil {
                        return false
                    }
                }
            } else if configuration.additionalHttpHeaders != nil && request.allHTTPHeaderFields == nil ||
                request.allHTTPHeaderFields != nil && configuration.additionalHttpHeaders == nil {
                    return false
            }
            
            return configuration.host == url
        }

        for task in tasks {
            guard !checkTaskRequest(task: task) else { return }
            do {
                try self.dbQueue?.inDatabase({ [weak self] db in
                    guard let record = try LogRecord.filter(Column("upload_task_id") == task.taskIdentifier).fetchOne(db) else { return }
                    task.cancel()
                    
                    self?.uploadLogRecord(logRecord: record, db: db)
                })
            } catch {
                print("SQL error recreating tasks: \(error)")
            }
        }
    }
    
    
    /// Ensures a `LogRecord` does not have an uploadTaskID not associated with any `URLSessionTasks` in the session.
    func cleanup() {
        // Get our tasks from the session and ensure we dont have a log record associated with a nonexistent task.
        urlSession?.getAllTasks { [weak self] tasks in
            guard let this = self else { return }
            do {
                try this.dbQueue?.inTransaction { db in
                    for record in try LogRecord.filter(Column("upload_task_id") != nil).fetchAll(db) {
                        if tasks.filter({ record.uploadTaskID == $0.taskIdentifier }).isEmpty {
                            record.uploadTaskID = nil
                            try record.update(db)
                             this.uploadLogRecord(logRecord: record, db: db)
                        }
                    }
                    
                    return .commit
                }
            } catch {
                print("SQL error cleaning up records: \(error)")
            }
            this.recreatePendingUploadTasksIfNeeded(tasks: tasks)
        }
    }
    
    private func deleteLogRecord(_ record: LogRecord, db: Database) {
        do {
            try record.delete(db)
            deleteTempFile(forRecord: record)
            if let delegate = delegate as? RelayTestingDelegate {
                delegate.relay(relay: self, didDeleteLogRecord: record)
            }
        } catch {
            print("sql error when deleting a record: \(error)")
        }
    }
    
    /// When a log succeeds or fails to upload, `processLogUploadTask` is called to do post processing.
    ///
    /// - Parameter task: The completed task.
    ///
    private func processLogUploadTask(task: URLSessionUploadTask, error: Error?) {
        do {
            try dbQueue?.inDatabase { db in
                guard let record = try LogRecord.filter(Column("upload_task_id") == task.taskIdentifier).fetchOne(db) else { return }
                if let error = error as? NSError, error.code == NSURLErrorCancelled {
                    deleteLogRecord(record, db: db)
                    return
                }
                if let httpResponse = task.response as? HTTPURLResponse {
                    if httpResponse.statusCode != 200 {
                        record.uploadTaskID = nil
                        record.uploadRetries += 1
                        try record.update(db)
                        // Should we toss it or try uploading it again?
                        if record.uploadRetries < uploadRetries {
                            uploadLogRecord(logRecord: record, db: db)
                        } else {
                            deleteLogRecord(record, db: db)
                        }
                        if let delegate  = delegate as? RelayTestingDelegate {
                            delegate.relay(relay: self, didFailToUploadLogRecord: record, error: task.error, response: httpResponse)
                        }
                        delegate?.relay(relay: self, didFailToUploadLogMessage: record.logMessage, error: task.error, response: httpResponse)
                    } else {
                        try record.delete(db)
                        deleteTempFile(forRecord: record)
                        if let delegate = delegate as? RelayTestingDelegate {
                            delegate.relay(relay: self, didUploadLogRecord: record)
                        }
                        delegate?.relay(relay: self, didUploadLogMessage: record.logMessage)
                    }
                }
            }
        } catch {
            print("SQL error processing log record: \(error)")
        }
    }
    
    
    /// Deletes a temporary file representing a `LogRecord`
    ///
    /// - Parameter record
    private func deleteTempFile(forRecord record: LogRecord) {
        let fileURL = relayPath().appendingPathComponent("\(record.uuid)")
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            print("unable to delete temporary log file: \(error)")
        }
    }
    
    // MARK: URLSessionTaskDelegate Methods
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let task = task as? URLSessionUploadTask {
            processLogUploadTask(task: task, error: error)
        }
        sessionCompletionHandler?()
    }
    
    // MARK: DDAbstractLogger Methods
    
    override public func log(message logMessage: DDLogMessage!) {
        // Generate a LogRecord from a LogMessage
        let logRecord = LogRecord(logMessage: logMessage, loggerIdentifier: identifier)
        do {
            try dbQueue?.inDatabase({ [weak self] db in
                let logRecordCount = try LogRecord.fetchCount(db)
                if logRecordCount >= (self?.maxNumberOfLogs)!,
                    let oldestLogRecord = try LogRecord.fetchOne(db, "SELECT * FROM log_messages ORDER BY date") {
                    self?.deleteLogRecord(oldestLogRecord, db: db)
                }
                try logRecord.save(db)
                DispatchQueue.global(qos: DispatchQoS.QoSClass.default).async {
                    guard let this = self else { return }
                    this.flushLogs()
                }
            })
        } catch {
            print("SQL error saving log record to the database: \(error)")
        }
    }
}
