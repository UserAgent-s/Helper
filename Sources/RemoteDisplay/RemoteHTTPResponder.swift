import Foundation

public enum RemoteHTTPResponder {
    public static let webSocketPortPlaceholder = "__WS_PORT__"

    public static func respond(to rawRequest: String, page: String, webSocketPort: UInt16?) -> Data {
        let requestLine = rawRequest.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return response(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: Data("bad request".utf8))
        }
        let method = String(parts[0])
        let target = String(parts[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        guard method == "GET" || method == "HEAD" else {
            return response(status: "405 Method Not Allowed", contentType: "text/plain; charset=utf-8", body: Data("method not allowed".utf8))
        }
        switch path {
        case "/", "/index.html":
            let rendered = page.replacingOccurrences(of: webSocketPortPlaceholder, with: webSocketPort.map(String.init) ?? "")
            return response(status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(rendered.utf8), headOnly: method == "HEAD")
        case "/health":
            let body = "{\"ok\":true,\"wsPort\":\(webSocketPort.map(String.init) ?? "null"),\"version\":\(RemoteOutboundMessage.protocolVersion)}"
            return response(status: "200 OK", contentType: "application/json", body: Data(body.utf8), headOnly: method == "HEAD")
        default:
            return response(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("not found".utf8))
        }
    }

    static func response(status: String, contentType: String, body: Data, headOnly: Bool = false) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        if !headOnly { data.append(body) }
        return data
    }
}
