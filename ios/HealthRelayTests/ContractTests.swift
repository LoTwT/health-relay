import XCTest
import Security
@testable import HealthRelay

final class ContractTests:XCTestCase {
    struct WorkoutFixture:Decodable{let dataset:Dataset;let group:ChangeSet}
    struct SleepFixture:Decodable{let name:String;let dataset:Dataset;let nowMs:Int64;let input:[SleepSample];let expected:[Change];let warnings:[String];let excludedMs:Int64;let deferred:Int}
    func fixture(_ name:String)throws->Data{
        let root=Bundle(for:Self.self).resourceURL!
        return try Data(contentsOf:root.appendingPathComponent("fixtures/\(name).json"))
    }
    func testSharedWorkoutContractPreservesInt64AndNull()throws{
        let f=try WireCodec.decode(WorkoutFixture.self,fixture("workout"));try Contract.validate(f.group,dataset:f.dataset)
        let encoded=try WireCodec.encode(f.group);let decoded=try WireCodec.decode(ChangeSet.self,encoded)
        XCTAssertEqual(decoded,f.group);XCTAssertEqual(decoded.changes[0].version,9_223_372_036_854_775_806)
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any]);let changes=try XCTUnwrap(json["changes"] as? [[String:Any]]);let payload=try XCTUnwrap(changes[0]["payload"] as? [String:Any]);let source=try XCTUnwrap(payload["source"] as? [String:Any]);XCTAssertTrue(source["model"] is NSNull)
    }
    func testSharedSleepFixtures()throws{
        let cases=try WireCodec.decode([SleepFixture].self,fixture("sleep-normalization"))
        for f in cases{
            let result=try Normalizer.sleep(f.input,dataset:f.dataset,now:f.nowMs)
            XCTAssertEqual(result.entities.map(\.entityId),f.expected.map(\.entityId),f.name)
            XCTAssertEqual(result.entities.map{Optional($0.payload)},f.expected.map(\.payload),f.name)
            XCTAssertEqual(result.excludedMilliseconds,f.excludedMs,f.name)
            XCTAssertEqual(result.deferred.count,f.deferred,f.name)
            for warning in f.warnings{XCTAssertTrue(result.warnings.contains(warning),f.name+warning)}
            if !result.entities.isEmpty{
                let group=ChangeSet(changeSetId:newID(),changes:result.entities.map{Change(entityId:$0.entityId,version:1,kind:"sleep",action:"upsert",payload:$0.payload)})
                try Contract.validate(group,dataset:f.dataset)
                XCTAssertEqual(try Normalizer.sleep(f.input.reversed(),dataset:f.dataset,now:f.nowMs).entities,result.entities,f.name)
            }
        }
    }
    func testInvalidSharedFixturesRejected()throws{
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:fixture("invalid-contract")) as? [String:Any])
        let dataset=try WireCodec.decode(Dataset.self,JSONSerialization.data(withJSONObject:object["dataset"]!))
        for item in object["cases"] as! [[String:Any]]{
            XCTAssertThrowsError(try Contract.validate(WireCodec.decode(ChangeSet.self,JSONSerialization.data(withJSONObject:item["group"]!)),dataset:dataset),item["name"] as! String)
        }
    }
    func testPinnedTLSCertificateRejectsWrongPinAndExpiry()throws{
        let url=Bundle(for:Self.self).resourceURL!.appendingPathComponent("fixtures/tls-certificate.der")
        let data=try Data(contentsOf:url);let certificate=try XCTUnwrap(SecCertificateCreateWithData(nil,data as CFData))
        var trust:SecTrust?;XCTAssertEqual(SecTrustCreateWithCertificates(certificate,SecPolicyCreateSSL(true,nil),&trust),errSecSuccess)
        let t=try XCTUnwrap(trust)
        XCTAssertTrue(PinnedCertificate.validate(t,fingerprint:sha256(data)),String(describing:SecTrustCopyResult(t)))
        XCTAssertFalse(PinnedCertificate.validate(t,fingerprint:String(repeating:"0",count:64)))
        let wrongUse=try Data(contentsOf:url.deletingLastPathComponent().appendingPathComponent("tls-client-only.der"))
        let clientCertificate=try XCTUnwrap(SecCertificateCreateWithData(nil,wrongUse as CFData))
        var clientTrust:SecTrust?;SecTrustCreateWithCertificates(clientCertificate,SecPolicyCreateBasicX509(),&clientTrust)
        XCTAssertFalse(PinnedCertificate.validate(try XCTUnwrap(clientTrust),fingerprint:sha256(wrongUse)))
        SecTrustSetVerifyDate(t,Date(timeIntervalSince1970:4_102_444_800) as CFDate)
        XCTAssertFalse(PinnedCertificate.validate(t,fingerprint:sha256(data)))
    }
    func testFrameBoundsAndFragmentedHeader()throws{
        XCTAssertThrowsError(try WireCodec.frameLength(Data([0,16,0,1])))
        XCTAssertThrowsError(try WireCodec.frameLength(Data([0,0,0,0])))
        XCTAssertEqual(try WireCodec.frameLength(Data([0,0,1,0])),256)
        XCTAssertEqual(try WireCodec.frame(Data([1,2,3])),Data([0,0,0,3,1,2,3]))
    }
    func testWorkoutPauseAndSourceSemantics()throws{
        let f=try WireCodec.decode(WorkoutFixture.self,fixture("workout"));let p=f.group.changes[0].payload!
        let s=try WireTime.milliseconds(p.start),e=try WireTime.milliseconds(p.end)
        var sample=WorkoutSample(uuid:p.sourceUuid!,startMs:s,endMs:e,durationMs:2700000,activity:"running",source:p.source,recordingMethod:"active",indoor:true,distanceMetres:0,activeKcal:325.5,events:[WorkoutEvent(timeMs:s+1200000,type:"pause"),WorkoutEvent(timeMs:s+1500000,type:"resume")])
        var result=try XCTUnwrap(Normalizer.workout(sample,dataset:f.dataset,now:e+1)).payload
        XCTAssertEqual(result.pauses,p.pauses);XCTAssertEqual(result.distance?.metres,0);XCTAssertEqual(result.exerciseType,"RUNNING");XCTAssertEqual(result.activeEnergy?.kcal,325.5)
        sample.events=[];sample.distanceMetres=nil;sample.activeKcal = -.infinity
        result=try XCTUnwrap(Normalizer.workout(sample,dataset:f.dataset,now:e+1)).payload
        XCTAssertEqual(result.pauses,[]);XCTAssertEqual(result.durationMs,2700000);XCTAssertTrue(result.warnings.contains("DURATION_NOT_FULLY_REPRESENTABLE"));XCTAssertEqual(result.distance?.state,"unavailable");XCTAssertEqual(result.activeEnergy?.state,"unavailable")
        sample.activity="swimming";XCTAssertEqual(try Normalizer.workout(sample,dataset:f.dataset,now:e+1)?.payload.exerciseType,"OTHER_WORKOUT")
        sample.activity="unknown:999";XCTAssertEqual(try Normalizer.workout(sample,dataset:f.dataset,now:e+1)?.payload.exerciseType,"OTHER_WORKOUT")
        sample.source.bundleIdentifier="another.source";XCTAssertNil(try Normalizer.workout(sample,dataset:f.dataset,now:e+1))
    }
    func testDSTOffsetsAndUnknown()throws{
        var source=Source(bundleIdentifier:"x",sourceKey:sha256("x"),timeZone:"America/New_York")
        XCTAssertEqual(Normalizer.offset(source,try WireTime.milliseconds("2026-11-01T05:30:00.000Z")),-14400)
        XCTAssertEqual(Normalizer.offset(source,try WireTime.milliseconds("2026-11-01T07:30:00.000Z")),-18000)
        source.timeZone=nil;XCTAssertNil(Normalizer.offset(source,0))
    }
}
