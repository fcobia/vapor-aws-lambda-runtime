import AWSLambdaEvents
import AWSLambdaRuntimeCore
import Base64Kit
import NIO
import NIOHTTP1
import Vapor

// MARK: - Handler -

struct APIGatewayV2Handler: EventLoopLambdaHandler {
    typealias In = APIGateway.V2.Request
    typealias Out = APIGateway.V2.Response

    private let application: Application
    private let responder: Responder

    init(application: Application, responder: Responder) {
        self.application = application
        self.responder = responder
    }

    public func handle(context: Lambda.Context, event: APIGateway.V2.Request)
        -> EventLoopFuture<APIGateway.V2.Response>
    {
        let vaporRequest: Vapor.Request
        do {
            vaporRequest = try Vapor.Request(req: event, in: context, for: application)
        } catch {
            return context.eventLoop.makeFailedFuture(error)
        }

        return responder.respond(to: vaporRequest)
            .map { APIGateway.V2.Response(response: $0) }
    }
}

// MARK: - Request -

extension Vapor.Request {
    private static let bufferAllocator = ByteBufferAllocator()

    convenience init(req: APIGateway.V2.Request, in ctx: Lambda.Context, for application: Application) throws {
        var buffer: NIO.ByteBuffer?
        switch (req.body, req.isBase64Encoded) {
        case (let .some(string), true):
            let bytes = try string.base64decoded()
            buffer = Vapor.Request.bufferAllocator.buffer(capacity: bytes.count)
            buffer!.writeBytes(bytes)

        case (let .some(string), false):
            buffer = Vapor.Request.bufferAllocator.buffer(capacity: string.utf8.count)
            buffer!.writeString(string)

        case (.none, _):
            break
        }

        var nioHeaders = NIOHTTP1.HTTPHeaders()
        req.headers.forEach { key, value in
            nioHeaders.add(name: key, value: value)
        }

        if let cookies = req.cookies, cookies.count > 0 {
            var cookiesStr = ""
            cookies.enumerated().forEach { entry in

                if entry.offset > 0 {
                    cookiesStr += "; "
                }

                cookiesStr += entry.element
            }

            nioHeaders.add(name: "Cookie", value: cookiesStr)
        }

        var url: String = req.rawPath
        if req.rawQueryString.count > 0 {
            url += "?\(req.rawQueryString)"
        }

        self.init(
            application: application,
            method: NIOHTTP1.HTTPMethod(rawValue: req.context.http.method.rawValue),
            url: Vapor.URI(path: url),
            version: HTTPVersion(major: 1, minor: 1),
            headers: nioHeaders,
            collectedBody: buffer,
            remoteAddress: nil,
            logger: ctx.logger,
            on: ctx.eventLoop
        )

        storage[APIGateway.V2.Request] = req
    }
}

extension APIGateway.V2.Request: Vapor.StorageKey {
    public typealias Value = APIGateway.V2.Request
}

// MARK: - Response -

extension APIGateway.V2.Response {
    init(response: Vapor.Response) {
		
		// FIXME: Debugging
		let logger = Logger(label: "codes.vapor.response")

		
        var headers = [String: String]()
        response.headers.forEach { name, value in
            if let current = headers[name] {
                headers[name] = "\(current),\(value)"
            } else {
                headers[name] = value
            }
        }

        if let string = response.body.string {
            self = .init(
                statusCode: AWSLambdaEvents.HTTPResponseStatus(code: response.status.code),
                headers: headers,
                body: string,
                isBase64Encoded: false
            )
			logger.info("Got here String body")
        } else if var buffer = response.body.buffer {
            let bytes = buffer.readBytes(length: buffer.readableBytes)!
            self = .init(
                statusCode: AWSLambdaEvents.HTTPResponseStatus(code: response.status.code),
                headers: headers,
                body: String(base64Encoding: bytes),
                isBase64Encoded: true
            )
			logger.info("Got here Buffer body: \(String(base64Encoding: bytes))")
        } else {
            self = .init(
                statusCode: AWSLambdaEvents.HTTPResponseStatus(code: response.status.code),
                headers: headers
            )
			logger.info("Got here String No body")
       }
		
		// FIXME: Debugging
		let jsonData = try? JSONEncoder().encode(self)
		let jsonString: String
		if let jsonData = jsonData {
			jsonString = String(bytes: jsonData, encoding: .utf8) ?? "Unable to convert data to string"
		}
		else {
			jsonString = "Error encoding response"
		}
		logger.info("Response: \(jsonString)")
    }
}
