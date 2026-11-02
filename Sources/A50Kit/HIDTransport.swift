import Foundation
import IOKit
import IOKit.hid

/// Canal de control de la base A50 Gen 4: una interfaz HID de fabricante
/// (usage page 0xFF32, usage 0x74) con informes de 64 bytes y report ID 2.
final class HIDTransport {
    static let vendorID = 0x9886
    /// `A50_TEST_PRODUCT_ID` solo existe para simular la base desenchufada en las pruebas.
    static let productID = Int(ProcessInfo.processInfo.environment["A50_TEST_PRODUCT_ID"] ?? "") ?? 0x002C
    static let usagePage = 0xFF32
    static let usage = 0x74
    static let reportID = 2
    static let reportSize = 64
    static let timeout: TimeInterval = 3  // SAVE_VALUES tarda más de 2 s
    static let settleMicroseconds: UInt32 = 6_000

    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private let queue = DispatchQueue(label: "es.verticelabs.a50.hid")
    private let inBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: HIDTransport.reportSize)

    private let requestLock = NSLock()
    private let stateLock = NSLock()
    private var waiter: DispatchSemaphore?
    private var replies: [[UInt8]] = []
    private var closed = false

    /// Informes que llegan sin que nadie los haya pedido (eventos de la base).
    var onUnsolicited: (([UInt8]) -> Void)?

    init() throws {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDProductIDKey: Self.productID,
            kIOHIDPrimaryUsagePageKey: Self.usagePage,
            kIOHIDPrimaryUsageKey: Self.usage,
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        let opened = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else { throw A50Error.openFailed(opened) }
        // Cierre explícito antes de fallar (la app reintenta cada 2 s con la base desenchufada). Medido: con o sin él
        // los puertos Mach se quedan planos de 10 a 20 000 reintentos; es por orden, no porque fugara.
        guard let found = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, let dev = found.first else {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            throw A50Error.notConnected
        }
        let r = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            throw A50Error.openFailed(r)
        }
        manager = mgr
        device = dev

        IOHIDDeviceRegisterInputReportCallback(
            device, inBuffer, Self.reportSize,
            { context, _, _, _, reportID, report, length in
                guard let context else { return }
                let me = Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue()
                me.received(Array(UnsafeBufferPointer(start: report, count: length)), reportID: Int(reportID))
            },
            Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceSetDispatchQueue(device, queue)
        IOHIDDeviceActivate(device)
    }

    deinit { close() }

    func close() {
        stateLock.lock()
        if closed { stateLock.unlock(); return }
        closed = true
        stateLock.unlock()
        let done = DispatchSemaphore(value: 0)
        IOHIDDeviceSetCancelHandler(device) { done.signal() }
        IOHIDDeviceCancel(device)
        _ = done.wait(timeout: .now() + 1)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        inBuffer.deallocate()
    }

    private func received(_ raw: [UInt8], reportID: Int) {
        // macOS entrega el informe con su ID delante (64 bytes); si llegara sin él (63) se lo ponemos.
        let bytes = (raw.count == Self.reportSize - 1 && reportID == Self.reportID) ? [UInt8(Self.reportID)] + raw : raw
        stateLock.lock()
        if let waiter {
            replies.append(bytes)
            stateLock.unlock()
            waiter.signal()
        } else {
            stateLock.unlock()
            onUnsolicited?(bytes)
        }
    }

    /// Cerrojo entre procesos. Cada cliente HID recibe TODOS los informes de entrada, así que dos
    /// procesos (la app y `a50ctl`) con una petición en vuelo a la vez se roban las respuestas.
    private static let processLock: Int32 = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/es.verticelabs.a50control")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return open(dir.appendingPathComponent("hid.lock").path, O_CREAT | O_RDWR, 0o600)
    }()

    /// Envía `[0x02, tipo, (len, payload…)]` y devuelve los datos de la respuesta.
    /// `echoes`: la respuesta repite el código de la petición en su primer byte de datos; si llega
    /// otra cosa es la respuesta de otro cliente y se descarta.
    func request(_ type: UInt8, _ payload: [UInt8] = [], echoes: Bool = false) throws -> [UInt8] {
        requestLock.lock()
        defer { requestLock.unlock() }
        if Self.processLock >= 0 { flock(Self.processLock, LOCK_EX) }
        defer {
            if Self.processLock >= 0 {
                usleep(Self.settleMicroseconds)  // deja que el informe llegue a los demás clientes antes de soltar
                flock(Self.processLock, LOCK_UN)
            }
        }

        var out = [UInt8](repeating: 0, count: Self.reportSize)
        out[0] = UInt8(Self.reportID)
        out[1] = type
        if !payload.isEmpty {
            precondition(payload.count + 3 <= Self.reportSize, "payload demasiado largo")
            out[2] = UInt8(payload.count)
            for (i, b) in payload.enumerated() { out[3 + i] = b }
        }

        let sem = DispatchSemaphore(value: 0)
        stateLock.lock()
        waiter = sem
        replies = []
        stateLock.unlock()
        defer { stateLock.lock(); waiter = nil; stateLock.unlock() }

        let sent = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(Self.reportID), out, out.count)
        guard sent == kIOReturnSuccess else { throw A50Error.writeFailed(sent) }

        let deadline = DispatchTime.now() + Self.timeout
        while true {
            guard sem.wait(timeout: deadline) == .success else { throw A50Error.timeout }
            stateLock.lock()
            let resp = replies.isEmpty ? [] : replies.removeFirst()
            stateLock.unlock()
            let data = try Self.parse(resp)
            if echoes && data.first != type { continue }
            return data
        }
    }

    static func parse(_ resp: [UInt8]) throws -> [UInt8] {
        guard resp.count >= 3, resp[0] == 0x02 else {
            throw A50Error.badResponse("cabecera inesperada: \(resp.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))")
        }
        // Algunos firmwares declaran una longitud mayor que la real.
        let length = min(Int(resp[2]), resp.count - 3)
        let data = Array(resp[3..<3 + length])
        switch resp[1] {
        case 0x00, 0x02:
            return data
        case 0x01:
            // Error: 4 bytes desconocidos y un mensaje terminado en NUL.
            let text = data.dropFirst(4).prefix { $0 > 0 }
            let message = String(decoding: text, as: UTF8.self)
            if message == "HID_ERROR_SLAVE_NO_SLAVE" { throw A50Error.headsetNotConnected }
            throw A50Error.requestFailed(message)
        default:
            throw A50Error.badResponse("estado desconocido \(resp[1])")
        }
    }
}
