import Foundation
import CryptoKit
import Security

/// The same native NeoY OAuth issuer used by the Harness. No Mobile-specific
/// token issuer. The existing saved Master access code is used once for PKCE
/// enrollment, and never exported to a different origin.
struct NeoMobileOAuthGrant: Codable, Sendable {
    let origin: String
    let clientID: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    var needsRefresh: Bool { expiresAt.timeIntervalSinceNow <= 120 }
}

enum NeoMobileOAuthError: LocalizedError {
    case invalidIssuer, invalidResponse, http(Int), randomUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidIssuer: "The saved Neo Master OAuth issuer is invalid."
        case .invalidResponse: "Neo Master returned an invalid OAuth response."
        case .http(let status): "Neo Master authentication failed (HTTP \(status))."
        case .randomUnavailable: "Secure credential generation is unavailable."
        }
    }
}
final class NeoMobileOAuthNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
enum NeoMobileOAuth {
    static let callback = "http://127.0.0.1:8765/neo/oauth/callback"

    static func origin(for endpoint: String) throws -> String {
        guard let url=URL(string:endpoint),var c=URLComponents(url:url,resolvingAgainstBaseURL:false),
              c.scheme=="https",c.host != nil,c.user==nil,c.password==nil,
              c.query==nil,c.fragment==nil,(c.path=="/mcp"||c.path=="/"||c.path.isEmpty)
        else{throw NeoMobileOAuthError.invalidIssuer}
        c.path=""
        guard let result=c.url?.absoluteString else{throw NeoMobileOAuthError.invalidIssuer}
        return result
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of:"+",with:"-")
            .replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
    }
    private static func random() throws -> String {
        var bytes=[UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess else{throw NeoMobileOAuthError.randomUnavailable}
        return base64URL(Data(bytes))
    }
    private static func form(_ fields:[String:String])->Data {
        // URLComponents query encoding leaves '+' unescaped. Encode all
        // non-unreserved bytes to keep form decoding unambiguous.
        let allowed=CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.sorted{$0.key<$1.key}.map{key,value in
            key.addingPercentEncoding(withAllowedCharacters:allowed)!+"="+value.addingPercentEncoding(withAllowedCharacters:allowed)!
        }.joined(separator:"&").utf8)
    }
    private static func send(_ origin:String,_ path:String,method:String="POST",data:Data?=nil,
                             type:String="application/x-www-form-urlencoded") async throws -> (Data,HTTPURLResponse) {
        guard (try? self.origin(for:origin))==origin,let url=URL(string:origin+path) else{throw NeoMobileOAuthError.invalidIssuer}
        var request=URLRequest(url:url);request.httpMethod=method;request.httpBody=data
        request.timeoutInterval=15
        request.setValue(type,forHTTPHeaderField:"Content-Type")
        request.setValue("no-store",forHTTPHeaderField:"Cache-Control")
        let config=URLSessionConfiguration.ephemeral;config.httpShouldSetCookies=false;config.urlCache=nil
        let session=URLSession(configuration:config,delegate:NeoMobileOAuthNoRedirect(),delegateQueue:nil)
        defer{session.invalidateAndCancel()}
        let (bytes,response)=try await session.data(for:request)
        guard let http=response as? HTTPURLResponse,bytes.count<=1_048_576 else{throw NeoMobileOAuthError.invalidResponse}
        return (bytes,http)
    }
    private static func object(_ data:Data,_ response:HTTPURLResponse,status:Int) throws -> [String:Any] {
        guard response.statusCode==status else{throw NeoMobileOAuthError.http(response.statusCode)}
        guard let result=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw NeoMobileOAuthError.invalidResponse}
        return result
    }
    private static func grant(_ data:Data,_ response:HTTPURLResponse,origin:String,client:String) throws -> NeoMobileOAuthGrant {
        let result=try object(data,response,status:200)
        guard let access=result["access_token"] as? String,!access.isEmpty,
              let refresh=result["refresh_token"] as? String,!refresh.isEmpty,
              let ttl=result["expires_in"] as? Int,(1...3600).contains(ttl) else{throw NeoMobileOAuthError.invalidResponse}
        return NeoMobileOAuthGrant(origin:origin,clientID:client,accessToken:access,refreshToken:refresh,
                                   expiresAt:Date().addingTimeInterval(TimeInterval(ttl)))
    }
    static func enroll(endpoint:String,operatorCode:String,deviceID:String) async throws -> NeoMobileOAuthGrant {
        let issuer=try origin(for:endpoint)
        guard UUID(uuidString:deviceID) != nil else{throw NeoMobileOAuthError.invalidResponse}
        let verifier=try random(),state=try random()
        let challenge=base64URL(Data(SHA256.hash(data:Data(verifier.utf8))))
        let registration=try JSONSerialization.data(withJSONObject:[
            "client_name":"Neo Mobile registered device: "+deviceID,"redirect_uris":[callback],
            "grant_types":["authorization_code","refresh_token"],"response_types":["code"],
            "token_endpoint_auth_method":"none"])
        let (registered,registeredResponse)=try await send(issuer,"/register",data:registration,type:"application/json")
        let obj=try object(registered,registeredResponse,status:201)
        guard let client=obj["client_id"] as? String,!client.isEmpty else{throw NeoMobileOAuthError.invalidResponse}
        let query=form(["response_type":"code","client_id":client,"redirect_uri":callback,
                        "code_challenge":challenge,"code_challenge_method":"S256","scope":"mcp",
                        "resource":issuer+"/mcp","state":state])
        let (page,authResponse)=try await send(issuer,"/authorize?"+String(decoding:query,as:UTF8.self),method:"GET")
        guard authResponse.statusCode==200 else{throw NeoMobileOAuthError.http(authResponse.statusCode)}
        let html=String(decoding:page,as:UTF8.self)
        guard let match=html.range(of:"name=\"rid\" value=\""),
              let end=html[match.upperBound...].firstIndex(of:"\"") else{throw NeoMobileOAuthError.invalidResponse}
        let rid=String(html[match.upperBound..<end])
        guard !rid.isEmpty,rid.utf8.allSatisfy({($0>=65&&$0<=90)||($0>=97&&$0<=122)||($0>=48&&$0<=57)||$0==45||$0==95})
        else{throw NeoMobileOAuthError.invalidResponse}
        let (_,approved)=try await send(issuer,"/authorize",data:form(["rid":rid,"token":operatorCode]))
        guard approved.statusCode==302 else{throw NeoMobileOAuthError.http(approved.statusCode)}
        guard let location=approved.value(forHTTPHeaderField:"Location"),
              let redirect=URLComponents(string:location),let expected=URLComponents(string:callback),
              redirect.scheme==expected.scheme,redirect.host==expected.host,redirect.port==expected.port,
              redirect.path==expected.path,redirect.user==nil,redirect.password==nil,redirect.fragment==nil
        else{throw NeoMobileOAuthError.invalidResponse}
        func param(_ name:String)->String? {
            let items=redirect.queryItems?.filter{$0.name==name} ?? []
            return items.count==1 ? items[0].value:nil
        }
        guard param("state")==state,param("iss")==issuer,let code=param("code"),!code.isEmpty
        else{throw NeoMobileOAuthError.invalidResponse}
        let (tokens,response)=try await send(issuer,"/token",data:form(["grant_type":"authorization_code",
            "client_id":client,"redirect_uri":callback,"code":code,"code_verifier":verifier]))
        return try grant(tokens,response,origin:issuer,client:client)
    }
    static func refresh(_ current:NeoMobileOAuthGrant) async throws -> NeoMobileOAuthGrant {
        let (data,response)=try await send(current.origin,"/token",data:form([
            "grant_type":"refresh_token","client_id":current.clientID,"refresh_token":current.refreshToken]))
        let next=try grant(data,response,origin:current.origin,client:current.clientID)
        guard next.refreshToken != current.refreshToken else{throw NeoMobileOAuthError.invalidResponse}
        return next
    }
    static func revoke(_ grant:NeoMobileOAuthGrant) async throws {
        for (token,wholeGrant) in [(grant.refreshToken,true),(grant.accessToken,false)]{
            let (_,response)=try await send(grant.origin,"/revoke",data:form(["token":token,"revoke_grant":wholeGrant ? "true":"false"]))
            guard response.statusCode==200 else{throw NeoMobileOAuthError.http(response.statusCode)}
        }
    }
}
