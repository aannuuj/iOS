import Foundation
import Sodium
import PromiseKit

enum WebhookJsonParseError: Error {
    case empty
    case base64
    case missingKey
    case decrypt
}

extension Promise where T == Data? {
    func webhookJson(
        on queue: DispatchQueue?,
        statusCode: Int? = nil,
        sodium: Sodium =  Sodium(),
        options: JSONSerialization.ReadingOptions = [.allowFragments]
    ) -> Promise<Any> {
        return then { optionalData -> Promise<Any> in
            if let data = optionalData {
                return Promise<Data>.value(data).definitelyWebhookJson(
                    on: queue,
                    statusCode: statusCode,
                    sodium: sodium,
                    options: options
                )
            } else {
                throw WebhookJsonParseError.empty
            }
        }
    }
}

extension Promise where T == Data {
    func webhookJson(
        on queue: DispatchQueue?,
        statusCode: Int? = nil,
        sodium: Sodium =  Sodium(),
        options: JSONSerialization.ReadingOptions = [.allowFragments]
    ) -> Promise<Any> {
        definitelyWebhookJson(on: queue, statusCode: statusCode, sodium: sodium, options: options)
    }

    // Exists so that the Data? -> Data one doesn't accidentally refer to itself
    fileprivate func definitelyWebhookJson(
        on queue: DispatchQueue?,
        statusCode: Int?,
        sodium: Sodium,
        options: JSONSerialization.ReadingOptions = [.allowFragments]
    ) -> Promise<Any> {
        switch statusCode {
        case 204, 205:
            return .value(())
        case 404:
            // mobile_app not loaded
            return .init(error: HomeAssistantAPI.APIError.mobileAppComponentNotLoaded)
        case 410:
            // config entry removed
            return .init(error: HomeAssistantAPI.APIError.webhookGone)
        default:
            break
        }

        return map(on: queue) { data -> Any in
            if data.isEmpty {
                return ()
            } else {
                return try JSONSerialization.jsonObject(with: data, options: options)
            }
        }.map { object in
            guard let dictionary = object as? [String: Any],
                let encoded = dictionary["encrypted_data"] as? String
            else {
                return object
            }

            guard let secret = Current.settingsStore.connectionInfo?.webhookSecret else {
                throw WebhookJsonParseError.missingKey
            }

            guard let decoded = sodium.utils.base642bin(encoded, variant: .ORIGINAL, ignore: nil) else {
                throw WebhookJsonParseError.base64
            }

            guard let decrypted = sodium.secretBox.open(
                nonceAndAuthenticatedCipherText: decoded,
                secretKey: secret.bytes
            ) else {
                throw WebhookJsonParseError.decrypt
            }

            if decrypted.isEmpty {
                return ()
            } else {
                return try JSONSerialization.jsonObject(with: Data(decrypted), options: options)
            }
        }
    }
}
