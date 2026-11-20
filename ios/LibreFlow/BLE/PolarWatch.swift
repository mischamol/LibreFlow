import Foundation
@preconcurrency import CoreBluetooth

/// Polar PSFTP over Bluetooth LE, as in the open-source Polar BLE SDK and polar_ble.py.
/// READ-ONLY: the only requests sent are GET (read a file or folder). The only notifications sent are
/// Polar's sync-session signals (INITIALIZE_SESSION, START_SYNC, STOP_SYNC, TERMINATE_SESSION),
/// exactly as the official SDK does. Nothing on the watch is written or deleted.
enum PolarError: LocalizedError, Equatable {
    case bluetoothOff, unauthorized, notFound, disconnected, noService, timeout, packetLost, protocolError(Int), unknownStatus(Int)
    var errorDescription: String? {
        switch self {
        case .bluetoothOff: return "Bluetooth is off."
        case .unauthorized: return "Bluetooth access is not allowed for this app (Settings › Privacy › Bluetooth)."
        case .notFound: return "Watch not found. Press Sync on the watch, or put it in pairing mode."
        case .disconnected: return "The watch disconnected."
        case .noService: return "This device does not offer Polar's file service."
        case .timeout: return "No answer from the watch (timeout)."
        case .packetLost: return "A Bluetooth packet was lost."
        case .protocolError(let c): return c == 103 ? "File or folder does not exist (103)." : c == 202 ? "Watch busy (202)." : "Watch error \(c)."
        case .unknownStatus(let s): return "Unknown packet status \(s)."
        }
    }
}

/// A FIFO of notification packets with an async, time-limited `next()`.
/// `push` is called synchronously from the Bluetooth queue, so packets stay in arrival order.
private final class PacketQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [[UInt8]] = []
    private var head = 0
    private var waiter: CheckedContinuation<[UInt8], Error>?
    private var gen = 0

    func push(_ p: [UInt8]) {
        lock.lock()
        if let w = waiter { waiter = nil; lock.unlock(); w.resume(returning: p); return }
        buffer.append(p)
        lock.unlock()
    }
    func fail(_ e: Error) {
        lock.lock(); let w = waiter; waiter = nil; lock.unlock()
        w?.resume(throwing: e)
    }
    func clear() { lock.lock(); buffer.removeAll(); head = 0; lock.unlock() }

    func next(timeout: Double) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[UInt8], Error>) in
            lock.lock()
            if head < buffer.count {
                let p = buffer[head]; head += 1
                if head > 512 { buffer.removeFirst(head); head = 0 }
                lock.unlock()
                c.resume(returning: p)
                return
            }
            gen += 1
            let my = gen
            waiter = c
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let w = (self.gen == my) ? self.waiter : nil
                if w != nil { self.waiter = nil }
                self.lock.unlock()
                w?.resume(throwing: PolarError.timeout)
            }
        }
    }
}

// State is only touched on `queue` (CoreBluetooth callbacks) or by the single sync task, one step at a time.
final class PolarWatch: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    static let service = CBUUID(string: "FEEE")
    static let mtuChar = CBUUID(string: "FB005C51-02E7-F387-1CAD-8ACD2D8DF0C8")   // requests + responses
    static let d2hChar = CBUUID(string: "FB005C52-02E7-F387-1CAD-8ACD2D8DF0C8")   // watch -> phone notifications
    static let h2dChar = CBUUID(string: "FB005C53-02E7-F387-1CAD-8ACD2D8DF0C8")   // phone -> watch notifications

    private let queue = DispatchQueue(label: "polar.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var mtu: CBCharacteristic?, h2d: CBCharacteristic?
    private let packets = PacketQueue()
    private var frameSize = 20

    private var stateWaiter: CheckedContinuation<Void, Error>?
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var notifyWaiter: CheckedContinuation<Void, Error>?
    private var writeReadyWaiter: CheckedContinuation<Void, Never>?
    private var nameFilter = "polar"

    var log: (String) -> Void = { _ in }
    private(set) var deviceName: String?

    /// Remembered watch (CoreBluetooth identifier) so a later sync connects directly.
    static var savedIdentifier: UUID? {
        get { UserDefaults.standard.string(forKey: "watchId").flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "watchId") }
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: connect

    private func waitPoweredOn() async throws {
        if central.state == .poweredOn { return }
        if central.state == .unauthorized { throw PolarError.unauthorized }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.central.state == .poweredOn { c.resume() } else { self.stateWaiter = c }
            }
        }
    }

    /// Wait (up to `timeout`) until the watch is reachable, connect and prepare the file channel.
    func connect(nameContains: String = "Polar", timeout: Double = 180) async throws {
        try await waitPoweredOn()
        nameFilter = nameContains.lowercased()
        log("Looking for the watch… (if it is not found within a few seconds, press Sync on the watch)")
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                self.connectWaiter = c
                // 1. A watch paired with this iPhone (e.g. via Polar Flow) is often kept connected by iOS itself and
                //    then does not advertise: pick it up from the system's connected peripherals.
                let connected = self.central.retrieveConnectedPeripherals(withServices: [Self.service, CBUUID(string: "180D"), CBUUID(string: "180A")])
                self.log("Already connected to this iPhone: \(connected.map { $0.name ?? "?" }.joined(separator: ", ").ifEmpty("none"))")
                if let p = connected.first(where: { ($0.name ?? "").lowercased().contains(self.nameFilter) || ($0.name ?? "").lowercased().contains("polar") }) {
                    self.peripheral = p
                    p.delegate = self
                    self.central.connect(p)
                // 2. A watch this app used before: iOS connects as soon as it advertises.
                } else if let id = Self.savedIdentifier, let p = self.central.retrievePeripherals(withIdentifiers: [id]).first {
                    self.peripheral = p
                    p.delegate = self
                    self.central.connect(p)
                }
                // 3. Also scan, for a watch in pairing mode or after pressing Sync.
                self.central.scanForPeripherals(withServices: nil, options: nil)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    if let w = self.connectWaiter {
                        self.connectWaiter = nil
                        self.central.stopScan()
                        if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
                        w.resume(throwing: PolarError.notFound)
                    }
                }
            }
        }
        log("Connected to \(deviceName ?? "watch"). Securing the link…")
        // Subscribing to the encrypted channel makes iOS pair / re-encrypt by itself (a pairing prompt may appear).
        var lastError: Error?
        for attempt in 1...3 {
            do {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    queue.async {
                        guard let p = self.peripheral, let ch = self.mtu else { c.resume(throwing: PolarError.noService); return }
                        self.notifyWaiter = c
                        p.setNotifyValue(true, for: ch)
                    }
                }
                lastError = nil
                break
            } catch {
                lastError = error
                log("Attempt \(attempt) failed (\(error.localizedDescription)); retrying…")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        if let e = lastError { throw e }
        queue.sync {
            if let p = peripheral {
                frameSize = max(20, p.maximumWriteValueLength(for: .withoutResponse))
                if let d2h = p.services?.first(where: { $0.uuid == Self.service })?.characteristics?.first(where: { $0.uuid == Self.d2hChar }) {
                    p.setNotifyValue(true, for: d2h)
                }
                Self.savedIdentifier = p.identifier
            }
        }
        log("Link ready (frame \(frameSize) bytes).")
    }

    func disconnect() {
        queue.async {
            self.central.stopScan()
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn, let w = stateWaiter { stateWaiter = nil; w.resume() }
        else if c.state == .unauthorized, let w = stateWaiter { stateWaiter = nil; w.resume(throwing: PolarError.unauthorized) }
        else if c.state == .poweredOff, let w = stateWaiter { stateWaiter = nil; w.resume(throwing: PolarError.bluetoothOff) }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = (p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "").lowercased()
        guard connectWaiter != nil, name.contains(nameFilter) || name.contains("polar") else { return }
        if let cur = peripheral, cur.identifier == p.identifier, cur.state != .disconnected { return }   // already connecting
        log("Found \(p.name ?? name) advertising (RSSI \(rssi)).")
        if let cur = peripheral, cur.identifier != p.identifier { c.cancelPeripheralConnection(cur) }
        c.stopScan()
        peripheral = p
        p.delegate = self
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        c.stopScan()
        peripheral = p
        p.delegate = self
        deviceName = p.name
        log("Bluetooth connection with \(p.name ?? "watch") open, looking for the file service…")
        p.discoverServices([Self.service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("Connecting failed: \(error?.localizedDescription ?? "unknown"). Still waiting…")
        if connectWaiter != nil { c.scanForPeripherals(withServices: nil, options: nil) }   // keep waiting
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? ".")")
        if connectWaiter != nil { c.scanForPeripherals(withServices: nil, options: nil) }   // still waiting: keep looking
        packets.fail(PolarError.disconnected)
        if let w = notifyWaiter { notifyWaiter = nil; w.resume(throwing: PolarError.disconnected) }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log("Service discovery failed: \(error.localizedDescription)") }
        log("Services: \((p.services ?? []).map { $0.uuid.uuidString }.joined(separator: ", "))")
        guard let s = p.services?.first(where: { $0.uuid == Self.service }) else {
            if let w = connectWaiter { connectWaiter = nil; w.resume(throwing: PolarError.noService) }
            return
        }
        p.discoverCharacteristics([Self.mtuChar, Self.d2hChar, Self.h2dChar], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        mtu = s.characteristics?.first { $0.uuid == Self.mtuChar }
        h2d = s.characteristics?.first { $0.uuid == Self.h2dChar }
        if let w = connectWaiter {
            connectWaiter = nil
            if mtu == nil { w.resume(throwing: PolarError.noService) } else { w.resume() }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if let error { log("Subscribe \(ch.uuid.uuidString.prefix(8)) failed: \(error.localizedDescription)") }
        guard ch.uuid == Self.mtuChar, let w = notifyWaiter else { return }
        notifyWaiter = nil
        if let error { w.resume(throwing: error) } else { w.resume() }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value else { return }
        if ch.uuid == Self.d2hChar {   // notification from the watch (only logged, never answered)
            log("Watch notification: \([UInt8](v).map { String(format: "%02x", $0) }.joined())")
            return
        }
        if ch.uuid == Self.mtuChar {
            let bytes = [UInt8](v)
            packets.push(bytes)   // synchronously: keeps the packet order
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        if let w = writeReadyWaiter { writeReadyWaiter = nil; w.resume() }
    }

    // MARK: PSFTP framing (RFC76)

    private func frames(_ data: [UInt8]) -> [[UInt8]] {
        let chunk = frameSize - 1
        var out: [[UInt8]] = [], i = 0, seq: UInt8 = 0, next: UInt8 = 0
        repeat {
            let part = Array(data[i..<min(data.count, i + chunk)])
            i += part.count
            let more = i < data.count
            out.append([(next | (more ? 0x06 : 0x02)) | (seq << 4)] + part)
            next = 1; seq = (seq + 1) & 0x0F
        } while i < data.count
        return out
    }

    private func write(_ frame: [UInt8], to ch: CBCharacteristic) async throws {
        guard let p = peripheral, p.state == .connected else { throw PolarError.disconnected }
        if !p.canSendWriteWithoutResponse {
            // wait until iOS can take the next write, but never forever
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                queue.async {
                    if p.canSendWriteWithoutResponse { c.resume(); return }
                    self.writeReadyWaiter = c
                    self.queue.asyncAfter(deadline: .now() + 2) {
                        if let w = self.writeReadyWaiter { self.writeReadyWaiter = nil; w.resume() }
                    }
                }
            }
        }
        p.writeValue(Data(frame), for: ch, type: .withoutResponse)
    }

    private func requestRaw(_ stream: [UInt8], timeout: Double) async throws -> [UInt8] {
        guard let ch = mtu else { throw PolarError.noService }
        packets.clear()
        for f in frames(stream) { try await write(f, to: ch) }
        var out: [UInt8] = [], expSeq: UInt8 = 0
        while true {
            let pkt = try await packets.next(timeout: min(timeout, Self.packetTimeout))   // per packet, not per file
            guard let h = pkt.first else { continue }
            let status = Int((h >> 1) & 3), seq = (h >> 4) & 0x0F
            if status == 0 {
                let err = pkt.count >= 3 ? Int(pkt[1]) | Int(pkt[2]) << 8 : pkt.count > 1 ? Int(pkt[1]) : 0
                if err == 0 { return out }
                throw PolarError.protocolError(err)
            }
            if seq != expSeq {
                try? await write([0, 0, 0], to: ch)   // cancel the transfer, as the SDK does
                throw PolarError.packetLost
            }
            expSeq = (seq + 1) & 0x0F
            out += pkt.dropFirst()
            if status == 1 { return out }
            if status != 3 { throw PolarError.unknownStatus(status) }
        }
    }

    /// GET a file or folder (PbPFtpOperation{command=GET, path}).
    static let packetTimeout = 20.0

    /// GET with up to 2 retries after a timeout or a lost packet (the watch sometimes misses a request).
    func get(_ path: String, timeout: Double = 60) async throws -> [UInt8] {
        let p = [UInt8](path.utf8)
        let op: [UInt8] = [0x08] + PB.varint(0) + [0x12] + PB.varint(UInt64(p.count)) + p
        let header: [UInt8] = [UInt8(op.count & 0xFF), UInt8((op.count >> 8) & 0x7F)]
        var attempt = 0
        while true {
            do { return try await requestRaw(header + op, timeout: timeout) }
            catch let e as PolarError {
                switch e {
                case .timeout, .packetLost:
                    attempt += 1
                    if attempt > 2 { throw e }
                    log("\(e == .timeout ? "No answer" : "Packet lost") for \(path); retrying (\(attempt)/2)…")
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                default: throw e
                }
            }
        }
    }

    /// List a folder: [(name, size)], folder names end with "/".
    func ls(_ path: String) async throws -> [(name: String, size: Int)] {
        let data = try await get(path.hasSuffix("/") ? path : path + "/")
        return PBMessage(data).all(1).compactMap { v in
            guard let e = v.data.map({ PBMessage($0) }), let n = e.first(1)?.data else { return nil }
            return (String(decoding: n, as: UTF8.self), e.int(2))
        }
    }

    // MARK: sync session signalling (Polar BLE SDK: sendInitializationAndStartSyncNotifications etc.)

    private func notify(_ id: UInt8, _ params: [UInt8] = []) async throws {
        guard let ch = h2d else { return }
        for f in frames([id] + params) { try await write(f, to: ch) }
    }
    func startSync() async throws {
        try await notify(8)              // INITIALIZE_SESSION
        try await notify(0)              // START_SYNC
        log("Sync session started.")
    }
    func stopSync() async throws {
        try await notify(1, [0x08, 0x01])   // STOP_SYNC {completed: true}
        try await notify(9)                  // TERMINATE_SESSION
        try await Task.sleep(nanoseconds: 800_000_000)
        log("Sync session finished.")
    }
}

extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}
