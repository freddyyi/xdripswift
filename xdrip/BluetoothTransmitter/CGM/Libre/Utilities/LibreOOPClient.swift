////
////  RemoteBG.swift
////  SwitftOOPWeb
////
////  Created by Bjørn Inge Berg on 08.04.2018.
////  Copyright © 2018 Bjørn Inge Berg. All rights reserved.
////
//
//
//  LibreOOPClient.swift
//  SwitftOOPWeb
//
//  Created by Bjørn Inge Berg on 08.04.2018.
//  Copyright © 2018 Bjørn Inge Berg. All rights reserved.
//
//
// adapted by Johan Degraeve for xdrip ios
import Foundation
import os

class LibreOOPClient {
    
    // MARK: - properties
    
    private static let filePath: String = NSHomeDirectory() + ConstantsLibreOOP.filePathForParameterStorage
    
    /// for trace
    private static let log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryLibreOOPClient)

    // MARK: - public functions
    
    public static func handleLibreData(libreData: Data, timeStampLastBgReading: Date, serialNumber: String, oopWebSite: String, oopWebToken: String, _ callback: @escaping ((glucoseData: [GlucoseData], sensorState: LibreSensorState, sensorTimeInMinutes: Int, errorDescription:String?)) -> Void) {
        
        let sensorState = LibreSensorState(stateByte: libreData[4])

        LibreOOPClient.calibrateSensor(bytes: libreData, serialNumber: serialNumber, site: oopWebSite, token: oopWebToken) {
            (libreDerivedAlgorithmParameters, errorDescription)  in
            
            // define default result that will be returned in defer statement
            var finalResult:[GlucoseData] = []
            
            let sensorTimeInMinutes:Int = 256 * (Int)(libreData.uint8(position: 317) & 0xFF) + (Int)(libreData.uint8(position: 316) & 0xFF)
            var errorDescription = errorDescription
            
            // before existing call callback function
            defer {
                callback((finalResult, sensorState, sensorTimeInMinutes, errorDescription))
            }

            // if errorDescription received from call to LibreOOPClient.calibrateSensor not nil then no need to continue
            if errorDescription != nil {return}
            
            guard let libreDerivedAlgorithmParameters = libreDerivedAlgorithmParameters else {
                // shouldn't happen because if libreDerivedAlgorithmParameters is nil,  it means something went wrong in call to calibrateSensor and so errorDescription should not be nil
                errorDescription = "libreDerivedAlgorithmParameters is nil"
                return
            }
            
            // iterates through glucoseData, compares timestamp, if still higher than timeStampLastBgReading (+ 30 seconds) then adds it to finalResult
            let processGlucoseData = { (glucoseData: [LibreRawGlucoseData], timeStampLastAddedGlucoseData: Date) in
                
                var timeStampLastAddedGlucoseDataAsDouble = timeStampLastAddedGlucoseData.toMillisecondsAsDouble()
                
                for glucose in glucoseData {
                    
                    let timeStampOfNewGlucoseData = glucose.timeStamp
                    if timeStampOfNewGlucoseData.toMillisecondsAsDouble() > (timeStampLastBgReading.toMillisecondsAsDouble() + 30000.0) {

                        // return only readings that are at least 5 minutes away from each other, except the first, same approach as in LibreDataParser.parse
                        if timeStampOfNewGlucoseData.toMillisecondsAsDouble() < timeStampLastAddedGlucoseDataAsDouble - (5 * 60 * 1000 - 10000) {
                            timeStampLastAddedGlucoseDataAsDouble = timeStampOfNewGlucoseData.toMillisecondsAsDouble()
                            finalResult.append(glucose)
                        }
                        
                    } else {
                        break
                    }
                }
                
            }

            // get last16 from trend data
            let last16 = trendMeasurements(bytes: libreData, date: Date(), timeStampLastBgReading: timeStampLastBgReading, LibreDerivedAlgorithmParameterSet: libreDerivedAlgorithmParameters)

            // process last16, new readings should be smaller than now + 5 minutes
            processGlucoseData(trendToLibreGlucose(last16), Date(timeIntervalSinceNow: 5 * 60))
            
            // get last 32 in history data, with date either again now = 5 minutes or timestamp of last reading in last16
            var lastTimeStamp = Date(timeIntervalSinceNow: 5 * 60)
            if finalResult.count > 0, let last = finalResult.last {
                lastTimeStamp = last.timeStamp
            }
            let last32 = historyMeasurements(bytes: libreData, date: lastTimeStamp, LibreDerivedAlgorithmParameterSet: libreDerivedAlgorithmParameters)
            
            // process last 32
            processGlucoseData(trendToLibreGlucose(last32), lastTimeStamp)
            
        }
    }

    private static func calibrateSensor(bytes: Data, serialNumber: String, site: String, token: String, callback: @escaping (LibreDerivedAlgorithmParameters?, _ errorDescription:String?) -> Void) {
        
        /// first try to get libreDerivedAlgorithmParameters for the sensor from disk
        let url = URL.init(fileURLWithPath: filePath)
        if FileManager.default.fileExists(atPath: url.path) {
            let decoder = JSONDecoder()
            do {
                let data = try Data.init(contentsOf: url)
                let libreDerivedAlgorithmParameters = try decoder.decode(LibreDerivedAlgorithmParameters.self, from: data)
                if libreDerivedAlgorithmParameters.serialNumber == serialNumber {
                    // successfully retrieved libreDerivedAlgorithmParameters for current sensor, from disk
                    callback(libreDerivedAlgorithmParameters, nil)
                    return
                }
            } catch {
                // data  not found on disk, we need to continue
            }
        }
        
        // get libreDerivedAlgorithmParameters from remote server
        post(bytes: bytes, site: site, token: token, { (data, errorDescription) in
            
            // define default result that will be returned in defer statement
            var libreDerivedAlgorithmParameters:LibreDerivedAlgorithmParameters? = nil
            var errorDescription = errorDescription
            defer {
                callback(libreDerivedAlgorithmParameters, errorDescription)
            }
            
            // if errorDescription is not nil then something went wrong
            if errorDescription != nil {return}
            
            // if data is nil then no need to continue
            guard let data = data else {
                // shouldn't happen because if data is nil it means something went wrong in call to post and so errorDescription should not be nil
                errorDescription = "data received form remote server is nil"
                return
            }
            
            var getCalibrationStatus:GetCalibrationStatus?
            do {
                getCalibrationStatus = try JSONDecoder().decode(GetCalibrationStatus.self, from: data)
            } catch {
                trace("Failed to decode data received from remote server. data received from remote server = %{public}@", log: log, category: ConstantsLog.categoryLibreOOPClient, type: .error, String(bytes: data, encoding: .utf8) ?? "")
                errorDescription =  String(bytes: data, encoding: .utf8) ?? "Failed to decode data received from remote server."
                return
            }

            if let getCalibrationStatus = getCalibrationStatus, let slope = getCalibrationStatus.slope {
                libreDerivedAlgorithmParameters = LibreDerivedAlgorithmParameters(slope_slope: slope.slopeSlope ?? 0, slope_offset: slope.slopeOffset ?? 0, offset_slope: slope.offsetSlope ?? 0, offset_offset: slope.offsetOffset ?? 0, isValidForFooterWithReverseCRCs: Int(slope.isValidForFooterWithReverseCRCs ?? 1), extraSlope: 1.0, extraOffset: 0.0, sensorSerialNumber: serialNumber)
                do {
                    let data = try JSONEncoder().encode(libreDerivedAlgorithmParameters)
                    save(data: data)
                } catch {
                    // encoding data failed, no need to handle as an error, it means probably next time a new post will be done to the oop web server
                    trace("in calibrateSensor, error while encoding data : %{public}@", log: log, category: ConstantsLog.categoryLibreOOPClient, type: .error, error.localizedDescription)
                }
            } else {
                trace("in calibrateSensor, slope is nil", log: log, category: ConstantsLog.categoryLibreOOPClient, type: .error)
                errorDescription = "slope is nil"
                return
            }
            
        })
    }
    
    // MARK: - private functions
    
    /// - parameters:
    ///     - bytes : the data to post
    ///     - site : the oop web site (inclusive http ...)
    ///     - token : the token to use
    ///     - completion : takes data returned from the remote server optional, errorDescription which is a string if anything went wrong, eg host could not be reached, if errorDescription not nil then it failed
    private static func post(bytes: Data, site: String, token: String, _ completion:@escaping (( _ data_: Data?, _ errorDescription: String?) -> Void)) {
        
        let date = Date().toMillisecondsAsInt64()

        let json: [String: String] = [
            "token": token,
            "content": "\(bytes.hexEncodedString())",
            "timestamp": "\(date)"]
        
        if let uploadURL = URL.init(string: site) {
            
            let request = NSMutableURLRequest(url: uploadURL)
            request.httpMethod = "POST"
            request.setBodyContent(contentMap: json)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            
            let task = URLSession.shared.dataTask(with: request as URLRequest) {
                data, urlResponse, error in
                
                // TODO: check urlResponse and http error code ? (see also NightScoutUploadManager)
                
                // define default result that will be returned in defer statement
                var errorDescription:String? = nil
                defer {
                    DispatchQueue.main.sync {
                        completion(data, errorDescription)
                    }
                }
                
                // error cases
                if let error = error {
                    
                    trace("post failed, error = %{public}@", log: self.log, category: ConstantsLog.categoryLibreOOPClient, type: .error, error.localizedDescription)
                    errorDescription = error.localizedDescription
                    return
                    
                }

            }
            
            task.resume()
        } else {
            completion(nil, "failed to create url from " + site)
        }
    }

    private static func save(data: Data) {
        let url = URL.init(fileURLWithPath: filePath)
        do {
            try data.write(to: url)
        } catch {
            trace("in save, failed to save data", log: log, category: ConstantsLog.categoryLibreOOPClient, type: .error)
        }
    }

    private static func trendMeasurements(bytes: Data, date: Date, timeStampLastBgReading: Date, _ offset: Double = 0.0, slope: Double = 0.1, LibreDerivedAlgorithmParameterSet: LibreDerivedAlgorithmParameters?) -> [LibreMeasurement] {
        
        //    let headerRange =   0..<24   //  24 bytes, i.e.  3 blocks a 8 bytes
        let bodyRange   =  24..<320  // 296 bytes, i.e. 37 blocks a 8 bytes
        //    let footerRange = 320..<344  //  24 bytes, i.e.  3 blocks a 8 bytes
        
        let body   = Array(bytes[bodyRange])
        let nextTrendBlock = Int(body[2])
        
        var measurements = [LibreMeasurement]()
        // Trend data is stored in body from byte 4 to byte 4+96=100 in units of 6 bytes. Index on data such that most recent block is first.
        for blockIndex in 0...15 {
            var index = 4 + (nextTrendBlock - 1 - blockIndex) * 6 // runs backwards
            if index < 4 {
                index = index + 96 // if end of ring buffer is reached shift to beginning of ring buffer
            }
            let range = index..<index+6
            let measurementBytes = Array(body[range])
            let measurementDate = date.addingTimeInterval(Double(-60 * blockIndex))
            
            if measurementDate > timeStampLastBgReading {
                let measurement = LibreMeasurement(bytes: measurementBytes, slope: slope, offset: offset, date: measurementDate, LibreDerivedAlgorithmParameterSet: LibreDerivedAlgorithmParameterSet)
                measurements.append(measurement)
            }
            
        }
        return measurements
    }
    
    private static func historyMeasurements(bytes: Data, date: Date, _ offset: Double = 0.0, slope: Double = 0.1, LibreDerivedAlgorithmParameterSet: LibreDerivedAlgorithmParameters?) -> [LibreMeasurement] {
        //    let headerRange =   0..<24   //  24 bytes, i.e.  3 blocks a 8 bytes
        let bodyRange   =  24..<320  // 296 bytes, i.e. 37 blocks a 8 bytes
        //    let footerRange = 320..<344  //  24 bytes, i.e.  3 blocks a 8 bytes
        
        let body   = Array(bytes[bodyRange])
        let nextHistoryBlock = Int(body[3])
        let minutesSinceStart = Int(body[293]) << 8 + Int(body[292])
        var measurements = [LibreMeasurement]()
        // History data is stored in body from byte 100 to byte 100+192-1=291 in units of 6 bytes. Index on data such that most recent block is first.
        for blockIndex in 0..<32 {
            
            var index = 100 + (nextHistoryBlock - 1 - blockIndex) * 6 // runs backwards
            if index < 100 {
                index = index + 192 // if end of ring buffer is reached shift to beginning of ring buffer
            }
            
            let range = index..<index+6
            let measurementBytes = Array(body[range])
            //            let measurementDate = dateOfMostRecentHistoryValue().addingTimeInterval(Double(-900 * blockIndex)) // 900 = 60 * 15
            //            let measurement = Measurement(bytes: measurementBytes, slope: slope, offset: offset, date: measurementDate)
            let (date, counter) = dateOfMostRecentHistoryValue(minutesSinceStart: minutesSinceStart, nextHistoryBlock: nextHistoryBlock, date: date)
            
            let final = date.addingTimeInterval(Double(-900 * blockIndex))
            let measurement = LibreMeasurement(bytes: measurementBytes, slope: slope, offset: offset, counter: counter - blockIndex * 15, date: final, LibreDerivedAlgorithmParameterSet: LibreDerivedAlgorithmParameterSet)
            measurements.append(measurement)
        }
        return measurements
    }
    
    private static func dateOfMostRecentHistoryValue(minutesSinceStart: Int, nextHistoryBlock: Int, date: Date) -> (date: Date, counter: Int) {
        // Calculate correct date for the most recent history value.
        //        date.addingTimeInterval( 60.0 * -Double( (minutesSinceStart - 3) % 15 + 3 ) )
        let nextHistoryIndexCalculatedFromMinutesCounter = ( (minutesSinceStart - 3) / 15 ) % 32
        let delay = (minutesSinceStart - 3) % 15 + 3 // in minutes
        if nextHistoryIndexCalculatedFromMinutesCounter == nextHistoryBlock {
            return (date: date.addingTimeInterval( 60.0 * -Double(delay) ), counter: minutesSinceStart - delay)
        } else {
            return (date: date.addingTimeInterval( 60.0 * -Double(delay - 15)), counter: minutesSinceStart - delay)
        }
    }

    private static func trendToLibreGlucose(_ measurements: [LibreMeasurement]) -> [LibreRawGlucoseData]{
        
        var origarr = [LibreRawGlucoseData]()
        
        for trend in measurements {
            let glucose = LibreRawGlucoseData(timeStamp: trend.date, unsmoothedGlucose: trend.temperatureAlgorithmGlucose)
            //debuglogging("in trendToLibreGlucose before CalculateSmothedData5Points, glucose.glucoseLevelRaw = " + glucose.glucoseLevelRaw.description + ", glucose.unsmoothedGlucose = " + glucose.unsmoothedGlucose.description)
            origarr.append(glucose)
        }
        
        return LibreGlucoseSmoothing.CalculateSmothedData5Points(origtrends: origarr)

        
    }

}
