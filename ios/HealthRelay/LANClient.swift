import Foundation
import Network
import Security

@MainActor enum PairingVault {
    static func read<T:Decodable>(_ type:T.Type,key:String) throws -> T? {
        var result:CFTypeRef?
        let status=SecItemCopyMatching([kSecClass:kSecClassGenericPassword,kSecAttrService:"app.healthrelay.ios",kSecAttrAccount:key,kSecReturnData:true,kSecMatchLimit:kSecMatchLimitOne] as CFDictionary,&result)
        if status==errSecItemNotFound{return nil}
        guard status==errSecSuccess,let data=result as? Data else{throw RelayError.authentication}
        return try WireCodec.decode(type,data)
    }
    static func save<T:Encodable>(_ value:T,key:String) throws {
        let query=[kSecClass:kSecClassGenericPassword,kSecAttrService:"app.healthrelay.ios",kSecAttrAccount:key] as [CFString:Any]
        let attributes=[kSecValueData:try WireCodec.encode(value),kSecAttrAccessible:kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as [CFString:Any]
        let status=SecItemUpdate(query as CFDictionary,attributes as CFDictionary)
        if status==errSecItemNotFound{
            guard SecItemAdd(query.merging(attributes){_,v in v} as CFDictionary,nil)==errSecSuccess else{throw RelayError.storage}
        }else if status != errSecSuccess{throw RelayError.storage}
    }
    static func remove(_ key:String){SecItemDelete([kSecClass:kSecClassGenericPassword,kSecAttrService:"app.healthrelay.ios",kSecAttrAccount:key] as CFDictionary)}
}

@MainActor final class LANClient {
    private var connection:NWConnection?
    private let queue=DispatchQueue(label:"app.healthrelay.network")
    private var readyContinuation:CheckedContinuation<Void,Error>?
    private var browser:NWBrowser?
    private var browseContinuation:CheckedContinuation<NWEndpoint?,Never>?
    func close(){connection?.cancel();connection=nil;browser?.cancel();browser=nil;readyContinuation?.resume(throwing:RelayError.network);readyContinuation=nil;browseContinuation?.resume(returning:nil);browseContinuation=nil}
    func discover(receiverId:String) async -> NWEndpoint? {
        let browser=NWBrowser(for:.bonjour(type:"_healthrelay._tcp",domain:nil),using:.tcp)
        self.browser=browser
        return await withCheckedContinuation { continuation in
            browseContinuation=continuation
            browser.browseResultsChangedHandler={ [weak self] results,_ in
                let endpoint=results.first { result in
                    if case let .service(name,_,_,_)=result.endpoint {return name.hasPrefix("health-relay-"+receiverId.prefix(8))};return false
                }?.endpoint
                if let endpoint{Task{@MainActor in self?.finishBrowse(endpoint)}}
            }
            browser.stateUpdateHandler={ [weak self] state in if case .failed=state{Task{@MainActor in self?.finishBrowse(nil)}} }
            browser.start(queue:queue)
            Task{try? await Task.sleep(for:.seconds(5));if self.browser === browser{finishBrowse(nil)}}
        }
    }
    private func finishBrowse(_ endpoint:NWEndpoint?){browseContinuation?.resume(returning:endpoint);browseContinuation=nil;browser?.cancel();browser=nil}
    func connect(endpoint:NWEndpoint,fingerprint:String) async throws {
        close()
        let tls=NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions,.TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions,.TLSv13)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions,{ _,trust,complete in
            complete(PinnedCertificate.validate(sec_trust_copy_ref(trust).takeRetainedValue(),fingerprint:fingerprint))
        },queue)
        let parameters=NWParameters(tls:tls,tcp:NWProtocolTCP.Options())
        parameters.requiredInterfaceType = .wifi
        let connection=NWConnection(to:endpoint,using:parameters);self.connection=connection
        try await withCheckedThrowingContinuation { continuation in
            readyContinuation=continuation
            connection.stateUpdateHandler={ [weak self] state in
                Task{@MainActor in
                    guard let self else{return}
                    switch state {
                    case .ready:self.readyContinuation?.resume();self.readyContinuation=nil
                    case .failed(let error):
                        let failure:RelayError
                        if case .tls=error{failure = .certificate}else{failure = .network}
                        self.readyContinuation?.resume(throwing:failure);self.readyContinuation=nil
                    case .cancelled:self.readyContinuation?.resume(throwing:RelayError.network);self.readyContinuation=nil
                    default:break
                    }
                }
            }
            connection.start(queue:queue)
            Task{try? await Task.sleep(for:.seconds(5));if self.connection === connection && readyContinuation != nil{close()}}
        }
    }
    func connect(_ pairing:Pairing,manual:(String,UInt16)?=nil) async throws {
        if let manual {try await connect(endpoint:.hostPort(host:NWEndpoint.Host(manual.0),port:NWEndpoint.Port(rawValue:manual.1)!),fingerprint:pairing.certificateFingerprint);return}
        if let endpoint=await discover(receiverId:pairing.receiverId){do{try await connect(endpoint:endpoint,fingerprint:pairing.certificateFingerprint);return}catch RelayError.certificate{throw RelayError.certificate}catch{}}
        try await connect(endpoint:.hostPort(host:NWEndpoint.Host(pairing.ip),port:NWEndpoint.Port(rawValue:pairing.port)!),fingerprint:pairing.certificateFingerprint)
    }
    private func readExactly(_ count:Int) async throws -> Data {
        guard let connection else{throw RelayError.network};var result=Data()
        while result.count<count{
            let remaining=count-result.count
            let data:Data=try await withCheckedThrowingContinuation{continuation in
                connection.receive(minimumIncompleteLength:1,maximumLength:remaining){data,_,complete,error in
                    if error != nil || data?.isEmpty != false{continuation.resume(throwing:RelayError.network)}else{continuation.resume(returning:data!)}
                }
            };result.append(data)
        };return result
    }
    func request(type:String,fields:[String:Any]=[:]) async throws -> [String:Any] {
        guard let connection else{throw RelayError.network}
        let id=newID();var message=fields;message["type"]=type;message["requestId"]=id;message["protocolVersion"]=1
        let frame=try WireCodec.frame(JSONSerialization.data(withJSONObject:message,options:[.sortedKeys,.withoutEscapingSlashes]))
        let timeout=Task{try await Task.sleep(for:.seconds(60));connection.cancel()};defer{timeout.cancel()}
        try await withCheckedThrowingContinuation{(continuation:CheckedContinuation<Void,Error>) in connection.send(content:frame,completion:.contentProcessed{error in if error != nil{continuation.resume(throwing:RelayError.network)}else{continuation.resume()}})}
        let length=try WireCodec.frameLength(await readExactly(4));let data=try await readExactly(length)
        guard let response=try JSONSerialization.jsonObject(with:data) as? [String:Any],response["requestId"] as? String==id,response["protocolVersion"] as? Int==1,response["type"] as? String=="result" else{throw RelayError.invalidPayload}
        guard response["ok"] as? Bool==true else{throw RelayError(rawValue:(response["error"] as? [String:Any])?["code"] as? String ?? "") ?? RelayError.invalidPayload}
        return response["result"] as? [String:Any] ?? [:]
    }
    func pair(_ code:PairingCode,dataset:Dataset,mode:String,senderId:String) async throws -> ([String:Any],Pairing) {
        guard code.protocol==1,code.port>0,IPv4Address(code.ip) != nil,code.certificateFingerprint.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil else{throw RelayError.invalidPayload}
        try await connect(endpoint:.hostPort(host:NWEndpoint.Host(code.ip),port:NWEndpoint.Port(rawValue:code.port)!),fingerprint:code.certificateFingerprint)
        let result=try await request(type:"pair",fields:["pairingId":code.pairingId,"pairingSecret":code.pairingSecret,"senderId":senderId,"senderName":"iPhone · health-relay","mode":mode,"datasetId":dataset.datasetId])
        guard let pairId=result["pairId"] as? String,let token=result["pairToken"] as? String,result["receiverId"] as? String==code.receiverId else{throw RelayError.authentication}
        let pairing=Pairing(receiverId:code.receiverId,certificateFingerprint:code.certificateFingerprint,pairId:pairId,pairToken:token,senderId:senderId,mode:mode,ip:code.ip,port:code.port)
        try PairingVault.save(pairing,key:"pairing");return (result,pairing)
    }
    func hello(_ pairing:Pairing,dataset:Dataset) async throws -> [String:Any] {
        var fields:[String:Any]=["pairId":pairing.pairId,"pairToken":pairing.pairToken,"senderId":pairing.senderId,"receiverId":pairing.receiverId,"mode":pairing.mode,"datasetId":dataset.datasetId]
        if pairing.mode=="normal"{
            guard let history=dataset.historyStart else{throw RelayError.history};fields["historyStart"]=history
            fields["sources"]=try JSONSerialization.jsonObject(with:WireCodec.encode(dataset.sources))
        }
        return try await request(type:"hello",fields:fields)
    }
}

// This trust policy is scoped to one NWConnection; it never changes system trust.
enum PinnedCertificate {
    static func validate(_ trust:SecTrust,fingerprint:String)->Bool {
        guard let chain=SecTrustCopyCertificateChain(trust) as? [SecCertificate],let leaf=chain.first,
              sha256(SecCertificateCopyData(leaf) as Data)==fingerprint else{return false}
        // A pinned ten-year private identity is not a public Web PKI certificate.
        // Basic X.509 verifies validity/signatures; the DER extensions below enforce TLS signing use.
        guard permitsTLSSigning(SecCertificateCopyData(leaf) as Data),
              let key=SecCertificateCopyKey(leaf),
              let attributes=SecKeyCopyAttributes(key) as? [CFString:Any],
              attributes[kSecAttrKeyType] as? String == kSecAttrKeyTypeECSECPrimeRandom as String,
              attributes[kSecAttrKeySizeInBits] as? Int == 256 else{return false}
        SecTrustSetPolicies(trust,SecPolicyCreateBasicX509())
        SecTrustSetAnchorCertificates(trust,[leaf] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust,true)
        SecTrustSetNetworkFetchAllowed(trust,false)
        return SecTrustEvaluateWithError(trust,nil)
    }
    private struct DER {
        let tag:UInt8;let bytes:[UInt8]
        static func read(_ bytes:[UInt8]) throws -> [DER] {
            var cursor=0;var result:[DER]=[]
            while cursor<bytes.count {
                guard cursor+2<=bytes.count else{throw RelayError.certificate}
                let tag=bytes[cursor];cursor+=1;let first=Int(bytes[cursor]);cursor+=1
                var length=first
                if first>=128 {
                    let count=first & 127
                    guard count>0,count<=4,cursor+count<=bytes.count else{throw RelayError.certificate}
                    length=0
                    for _ in 0..<count{length=(length<<8)|Int(bytes[cursor]);cursor+=1}
                    guard length>=128 else{throw RelayError.certificate}
                }
                guard length<=bytes.count-cursor else{throw RelayError.certificate}
                result.append(DER(tag:tag,bytes:Array(bytes[cursor..<cursor+length])));cursor+=length
            }
            return result
        }
        func children() throws -> [DER]{try Self.read(bytes)}
    }
    private static func permitsTLSSigning(_ certificate:Data)->Bool {
        do {
            let roots=try DER.read(Array(certificate));guard roots.count==1,roots[0].tag==0x30 else{return false}
            let certificateFields=try roots[0].children();guard certificateFields.count==3 else{return false}
            let fields=try certificateFields[0].children()
            // Absent KU/EKU imposes no use restriction under X.509 (Android Keystore's default).
            guard let extensions=fields.first(where:{$0.tag==0xa3}) else{return true}
            let wrapper=try extensions.children();guard wrapper.count==1,wrapper[0].tag==0x30 else{return false}
            var seen=Set<[UInt8]>()
            for item in try wrapper[0].children() {
                let values=try item.children()
                guard values.count>=2,values[0].tag==6,let value=values.last,value.tag==4,seen.insert(values[0].bytes).inserted else{return false}
                let oid=values[0].bytes
                if oid == [0x55,0x1d,0x0f] { // keyUsage: digitalSignature
                    let bits=try DER.read(value.bytes)
                    guard bits.count==1,bits[0].tag==3,bits[0].bytes.count>=2,bits[0].bytes[1]&0x80 != 0 else{return false}
                }
                if oid == [0x55,0x1d,0x25] { // extendedKeyUsage: serverAuth or anyExtendedKeyUsage
                    let sequence=try DER.read(value.bytes)
                    guard sequence.count==1,sequence[0].tag==0x30 else{return false}
                    let uses=try sequence[0].children()
                    guard uses.contains(where:{$0.tag==6 && ($0.bytes == [0x2b,6,1,5,5,7,3,1] || $0.bytes == [0x55,0x1d,0x25,0])}) else{return false}
                }
            }
            return true
        }catch{return false}
    }
}
